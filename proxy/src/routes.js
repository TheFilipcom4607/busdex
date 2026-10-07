// Every bus and tram line's street shapes and stops, built daily from ZTM's GTFS by
// scripts/build_routes.py in a GitHub Action, which uploads it here. Phones fetch it once a
// day to draw where a vehicle on HUNT goes next.
//
// Stored gzipped in KV (about 0.6 MB, one write a day), with its ETag alongside, so a phone
// that already has today's copy gets a 304 without the Worker reading the body.

const KEY = 'routes';
const GTFS = 'https://gtfs.ztm.waw.pl/last/';
const POJAZDY = 'https://dane.um.warszawa.pl/api/action/get_ztm_pojazdy';
// Fewer lines than this means a broken build (a normal day has about 300): keep yesterday's.
const MIN_LINES = 200;

export async function getRoutes(request, env) {
  const meta = await env.ROUTES.get(`${KEY}:meta`, { type: 'json', cacheTtl: 300 });
  if (!meta) return json({ result: 'No routes yet' }, 404);
  const headers = { ETag: meta.etag, 'Cache-Control': 'no-cache', 'X-Tabor-Feed': meta.feed };
  if (request.headers.get('If-None-Match') === meta.etag) return new Response(null, { status: 304, headers });
  const body = await env.ROUTES.get(KEY, { type: 'arrayBuffer', cacheTtl: 300 });
  if (!body) return json({ result: 'No routes yet' }, 404);
  // Already gzipped: 'manual' tells the runtime to send it as it is instead of compressing again.
  return new Response(body, {
    headers: { ...headers, 'Content-Type': 'application/json; charset=utf-8', 'Content-Encoding': 'gzip' },
    encodeBody: 'manual',
  });
}

// ZTM's GTFS, passed straight through for the Action: gtfs.ztm.waw.pl doesn't answer GitHub's
// runners (the connection times out), but it does answer Cloudflare. Streamed, never held.
export async function getGtfs(request, env) {
  if (!(await authorized(request, env))) return json({ result: 'Unauthorized' }, 401);
  let res;
  try {
    res = await fetch(GTFS, { headers: { 'User-Agent': 'tabor-routes/1' } });
  } catch (e) {
    console.log(`gtfs: ${e}`);
    return json({ result: `ZTM didn't answer: ${e}` }, 502);
  }
  if (!res.ok) {
    console.log(`gtfs: ZTM answered ${res.status} (colo ${request.cf?.colo})`);
    return json({ result: `ZTM answered ${res.status}` }, 502);
  }
  return new Response(res.body, {
    headers: { 'Content-Type': 'application/zip', 'Content-Length': res.headers.get('Content-Length') ?? '' },
  });
}

// The city's vehicle list, passed through for the nightly fleet Action (fleet.yml): like the
// GTFS, dane.um.warszawa.pl lets GitHub's runners time out but answers from Warsaw. Streamed
// untouched, since parsing 1.3 MB would blow the 10 ms of CPU.
export async function getPojazdy(request, env) {
  if (!(await authorized(request, env))) return json({ result: 'Unauthorized' }, 401);
  let res;
  try {
    res = await fetch(POJAZDY, {
      method: 'POST',
      headers: { Authorization: env.DANE_TOKEN, 'Content-Type': 'application/json' },
      body: '{}',
      signal: AbortSignal.timeout(50_000),
    });
  } catch (e) {
    console.log(`pojazdy: ${e}`);
    return json({ result: `The city didn't answer: ${e}` }, 502);
  }
  if (!res.ok) {
    console.log(`pojazdy: the city answered ${res.status} (colo ${request.cf?.colo})`);
    return json({ result: `The city answered ${res.status}` }, 502);
  }
  return new Response(res.body, { headers: { 'Content-Type': 'application/json; charset=utf-8' } });
}

// The Action sends the file already gzipped, with its line count and feed in headers: parsing
// and compressing 2.7 MB here would blow the free plan's 10 ms of CPU a call.
export async function putRoutes(request, env) {
  if (!(await authorized(request, env))) return json({ result: 'Unauthorized' }, 401);
  const lines = Number(request.headers.get('X-Routes-Lines'));
  if (!(lines > MIN_LINES)) return json({ result: `Only ${lines || 0} lines: keeping the old routes` }, 422);
  const gzipped = await request.arrayBuffer();
  const head = new Uint8Array(gzipped, 0, Math.min(2, gzipped.byteLength));
  if (gzipped.byteLength < 100_000 || head[0] !== 0x1f || head[1] !== 0x8b) {
    return json({ result: 'Expected a gzipped routes.json' }, 400);
  }
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', gzipped));
  const etag = `"${[...hash.slice(0, 12)].map((b) => b.toString(16).padStart(2, '0')).join('')}"`;
  const meta = { etag, feed: request.headers.get('X-Routes-Feed') ?? '', lines, bytes: gzipped.byteLength };
  // Body first: a phone reading the new ETag must find the body it names.
  await env.ROUTES.put(KEY, gzipped);
  await env.ROUTES.put(`${KEY}:meta`, JSON.stringify(meta));
  console.log(`routes: ${meta.feed}, ${lines} lines, ${gzipped.byteLength} bytes`);
  return json({ result: 'ok', ...meta }, 200);
}

async function authorized(request, env) {
  return !!env.ROUTES_UPLOAD_TOKEN
    && sameText(request.headers.get('Authorization') ?? '', `Bearer ${env.ROUTES_UPLOAD_TOKEN}`);
}

// Compares hashes, so how long it takes doesn't give away how much of a guess was right.
async function sameText(a, b) {
  const enc = new TextEncoder();
  const [x, y] = await Promise.all([a, b].map((s) => crypto.subtle.digest('SHA-256', enc.encode(s))));
  return crypto.subtle.timingSafeEqual(x, y);
}

function json(obj, status) {
  return new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
}
