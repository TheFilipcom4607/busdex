// TABOR's live-feed proxy. Phones ask here instead of api.um.warszawa.pl, so the city key
// stays a Worker secret instead of shipping inside the app, and every phone near one
// Cloudflare location shares a single upstream call every few seconds.
//
//   GET /v1/vehicles?type=1   buses
//   GET /v1/vehicles?type=2   trams
//   GET /v1/routes            every line's street shapes and stops (routes.js)
//   PUT /v1/routes            the daily upload of those, from the GitHub Action
//   GET /v1/gtfs              ZTM's GTFS zip, passed through for that Action
//   GET /v1/fleet/5221        what a vehicle is (model, year, specs), for other projects (lookup.js)
//   POST/DELETE /v1/track     a phone following a vehicle on its Lock Screen (track.js)
//
// The vehicles body is the old service's shape, {"result": [...]}, whichever service
// answered, so the app parses it exactly as before.

import { fetchDane, fetchOld } from './city.js';
import { lookup } from './lookup.js';
import { getGtfs, getRoutes, putRoutes } from './routes.js';
import { handleTrack } from './track.js';

export { Tracker } from './track.js';

// The city moves vehicles every ~10 s, but each vehicle on its own clock, so any copy held
// here only adds to how old a position is when it reaches the map. A few seconds still lets
// every phone near one Cloudflare location share a single upstream call.
const FRESH_SECONDS = 3;
// When the city stumbles (it drops calls under load), a copy this old still beats nothing;
// the app ignores positions older than a few minutes anyway.
const FALLBACK_SECONDS = 120;
// After both services fail, answer from the fallback copy for a while instead of making
// every phone wait out the timeouts again.
const DOWN_SECONDS = 15;

// Browsers on other sites may read the public feeds. The token-gated and app-only endpoints
// get no CORS headers, so a web page can't call them.
const PUBLIC = ['/v1/vehicles', '/v1/routes'];
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'If-None-Match',
  'Access-Control-Expose-Headers': 'ETag, X-Tabor-Cache, X-Tabor-Feed',
  'Access-Control-Max-Age': '86400',
};

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const fleet = url.pathname === '/v1/fleet' || url.pathname.startsWith('/v1/fleet/');
    if (!fleet && !PUBLIC.includes(url.pathname)) return handle(request, env, ctx, url);
    // A browser asks first before a GET carrying If-None-Match. Nothing goes upstream, so it
    // doesn't count against the limit.
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
    // Before the app's limit, under its own: lookups mustn't use up a phone's polls.
    if (fleet) return withCors(await lookup(request, env, url));
    return withCors(await handle(request, env, ctx, url));
  },
};

async function handle(request, env, ctx, url) {
  if (!['/v1/vehicles', '/v1/routes', '/v1/gtfs', '/v1/track'].includes(url.pathname)) return json({ result: 'Not found' }, 404);

  // A phone polls twice (buses, trams) every 10 s, 12 calls a minute. The limit leaves room
  // for several phones behind one carrier NAT, and stops a script hammering the key.
  const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  const { success } = await env.PER_IP.limit({ key: ip });
  if (!success) return json({ result: 'Too many requests' }, 429);

  if (url.pathname === '/v1/track') return handleTrack(request, env);
  if (url.pathname === '/v1/gtfs') return request.method === 'GET' ? getGtfs(request, env) : json({ result: 'GET only' }, 405);
  if (url.pathname === '/v1/routes') {
    if (request.method === 'GET') return getRoutes(request, env);
    if (request.method === 'PUT') return putRoutes(request, env);
    return json({ result: 'GET or PUT only' }, 405);
  }
  if (request.method !== 'GET') return json({ result: 'GET only' }, 405);
  const type = url.searchParams.get('type');
  if (type !== '1' && type !== '2') return json({ result: 'type must be 1 (buses) or 2 (trams)' }, 400);

  const cache = caches.default;
  const freshKey = new Request(`https://cache.tabor/fresh/${type}`);
  const goodKey = new Request(`https://cache.tabor/good/${type}`);
  const downKey = new Request(`https://cache.tabor/down/${type}`);

  const hit = await cache.match(freshKey);
  if (hit) return reply(await hit.text(), 'HIT');

  const down = await cache.match(downKey);
  let list = null;
  let source = 'dane';
  if (!down) {
    list = await fetchDane(type, env.DANE_TOKEN);
    if (!list) {
      source = 'old';
      list = await fetchOld(type, env.UM_KEY);
    }
  }
  if (list) {
    const body = JSON.stringify({ result: list });
    ctx.waitUntil(Promise.all([
      cache.put(freshKey, cached(body, FRESH_SECONDS)),
      cache.put(goodKey, cached(body, FALLBACK_SECONDS)),
    ]));
    // Which city service answered, for the logs: once it's always 'dane', the old key can go.
    console.log(`type ${type} from ${source}`);
    return reply(body, `MISS ${source}`);
  }
  if (!down) {
    console.log(`type ${type}: the city didn't answer`);
    ctx.waitUntil(cache.put(downKey, cached('{}', DOWN_SECONDS)));
  }
  const stale = await cache.match(goodKey);
  if (stale) return reply(await stale.text(), 'STALE');
  return json({ result: "The city's feed didn't answer" }, 502);
}

// Every response here is built by this Worker, so its headers can be changed in place. A new
// Response around the body would gzip the already gzipped routes again.
function withCors(res) {
  for (const [name, value] of Object.entries(CORS)) res.headers.set(name, value);
  return res;
}

function cached(body, seconds) {
  return new Response(body, { headers: { 'Content-Type': 'application/json', 'Cache-Control': `max-age=${seconds}` } });
}

// Cloudflare gzips JSON on the way out; the city's own responses aren't compressed.
function reply(body, cache) {
  return new Response(body, {
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Tabor-Cache': cache },
  });
}

function json(obj, status) {
  return new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
}
