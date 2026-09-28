// Every bus and tram line's street shapes and stops, built daily from ZTM's GTFS by
// scripts/build_routes.py in a GitHub Action, which uploads it here. Phones fetch it once a
// day to draw where a vehicle on HUNT goes next.
//
// Stored gzipped in KV (about 0.6 MB, one write a day), with its ETag alongside, so a phone
// that already has today's copy gets a 304 without the Worker reading the body.

const KEY = 'routes';
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

export async function putRoutes(request, env) {
  if (!env.ROUTES_UPLOAD_TOKEN || !(await sameText(request.headers.get('Authorization') ?? '', `Bearer ${env.ROUTES_UPLOAD_TOKEN}`))) {
    return json({ result: 'Unauthorized' }, 401);
  }
  const text = await request.text();
  let routes;
  try {
    routes = JSON.parse(text);
  } catch {
    return json({ result: "The body isn't JSON" }, 400);
  }
  const lines = Object.keys(routes?.lines ?? {}).length;
  if (lines <= MIN_LINES) return json({ result: `Only ${lines} lines: keeping the old routes` }, 422);

  const bytes = new TextEncoder().encode(text);
  const gzipped = await new Response(new Blob([bytes]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer();
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  const etag = `"${[...hash.slice(0, 12)].map((b) => b.toString(16).padStart(2, '0')).join('')}"`;
  const meta = { etag, feed: routes.feed ?? '', built: routes.built ?? '', lines, bytes: gzipped.byteLength };
  // Body first: a phone reading the new ETag must find the body it names.
  await env.ROUTES.put(KEY, gzipped);
  await env.ROUTES.put(`${KEY}:meta`, JSON.stringify(meta));
  console.log(`routes: ${meta.feed}, ${lines} lines, ${gzipped.byteLength} bytes`);
  return json({ result: 'ok', ...meta }, 200);
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
