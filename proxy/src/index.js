// TABOR's live-feed proxy. Phones ask here instead of api.um.warszawa.pl, so the city key
// stays a Worker secret instead of shipping inside the app, and every phone near one
// Cloudflare location shares a single upstream call every few seconds.
//
//   GET /v1/vehicles?type=1   buses
//   GET /v1/vehicles?type=2   trams
//
// The body is the city's own JSON, untouched, so the app parses it exactly as before.

// The city is moving its open data from api.um.warszawa.pl to dane.um.warszawa.pl and will
// switch the old one off. The new one comes first; the old one covers for it until then.
const DANE = 'https://dane.um.warszawa.pl/api/action/get_ztm_lokalizacja_pojazdow';
const OLD = 'https://api.um.warszawa.pl/api/action/busestrams_get/';
const OLD_RESOURCE = 'f2e5503e-927d-4ad3-9500-4ab9e55deb59';
// The city moves vehicles every ~10 s and phones poll every 15 s: fresher is wasted.
const FRESH_SECONDS = 10;
// When the city stumbles (it drops calls under load), a copy this old still beats nothing;
// the app ignores positions older than a few minutes anyway.
const FALLBACK_SECONDS = 120;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method !== 'GET') return json({ result: 'GET only' }, 405);
    if (url.pathname !== '/v1/vehicles') return json({ result: 'Not found' }, 404);
    const type = url.searchParams.get('type');
    if (type !== '1' && type !== '2') return json({ result: 'type must be 1 (buses) or 2 (trams)' }, 400);

    // A phone polls twice (buses, trams) every 15 s, 8 calls a minute. The limit leaves room
    // for several phones behind one carrier NAT, and stops a script hammering the key.
    const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
    const { success } = await env.PER_IP.limit({ key: ip });
    if (!success) return json({ result: 'Too many requests' }, 429);

    const cache = caches.default;
    const freshKey = new Request(`https://cache.tabor/fresh/${type}`);
    const goodKey = new Request(`https://cache.tabor/good/${type}`);

    const hit = await cache.match(freshKey);
    if (hit) return reply(await hit.text(), 'HIT');

    let body = await fetchDane(type, env.DANE_TOKEN);
    const source = body ? 'dane' : 'old';
    body ??= await fetchOld(type, env.UM_KEY);
    if (body) {
      ctx.waitUntil(Promise.all([
        cache.put(freshKey, cached(body, FRESH_SECONDS)),
        cache.put(goodKey, cached(body, FALLBACK_SECONDS)),
      ]));
      // Which city service answered, for the logs: once it's always 'dane', the old key can go.
      console.log(`type ${type} from ${source}`);
      return reply(body, `MISS ${source}`);
    }
    const stale = await cache.match(goodKey);
    if (stale) return reply(await stale.text(), 'STALE');
    return json({ result: "The city's feed didn't answer" }, 502);
  },
};

// Both return the old service's shape, {"result": [...]}, or null if the call failed.

// The new service sends a bare list, and answers a bad token with a 500.
async function fetchDane(type, token) {
  if (!token) return null;
  try {
    const res = await fetch(DANE, {
      method: 'POST',
      headers: { Authorization: token, 'Content-Type': 'application/json' },
      body: JSON.stringify({ type: Number(type) }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) return null;
    const list = await res.json();
    return Array.isArray(list) ? JSON.stringify({ result: list }) : null;
  } catch {
    return null;
  }
}

// The old service answers errors with 200 and a message in `result` instead of the list,
// so those count as failures too and never get cached.
async function fetchOld(type, key) {
  if (!key) return null;
  const url = `${OLD}?resource_id=${OLD_RESOURCE}&type=${type}&apikey=${encodeURIComponent(key)}`;
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(15_000) });
    if (!res.ok) return null;
    const body = await res.text();
    return Array.isArray(JSON.parse(body).result) ? body : null;
  } catch {
    return null;
  }
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
