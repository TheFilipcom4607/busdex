// What a vehicle is, from its fleet number: model, year, operator, depot, specs. For other
// projects; the app has all of this in its own fleet.json and never calls it.
//
//   GET /v1/fleet/5221                 one vehicle
//   GET /v1/fleet/5221?type=bus        buses only (or tram; 1 and 2 work too, as in /v1/vehicles)
//   GET /v1/fleet/5221,1983,1000       up to 100 in one call, keyed by number, for a live map
//
// Least priority by design. It has its own rate limit (LOOKUP_PER_IP), so lookups from an
// address never use up a phone's polls there, and nothing the app calls waits on it. The
// data is the fleet.json the app downloads, fetched from GitHub through Cloudflare's cache at
// most once a day per location: a fleet update reaches lookups by the next day, not at once.

const FLEET = 'https://raw.githubusercontent.com/TheFilipcom4607/busdex/main/Tabor/Resources/fleet.json';
const TYPES = { 1: 'BUS', 2: 'TRAM', bus: 'BUS', tram: 'TRAM' };
const MAX_NUMBERS = 100;
const USAGE = 'Look a vehicle up by its fleet number: /v1/fleet/5221, or several at once: /v1/fleet/5221,1983 '
  + '(add ?type=bus or ?type=tram when you know which)';
// How long a fetched copy is reused: on the edge, and parsed in this isolate's memory, which
// keeps the 69 KB parse off almost every call.
const EDGE_SECONDS = 86_400;
const MEMORY_MS = 60 * 60_000;
const FLOORS = { LF: 'low', LE: 'low entry', HF: 'high' };

let memo = null;

export async function lookup(request, env, url) {
  if (request.method !== 'GET') return json({ result: 'GET only' }, 405);
  const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  const { success } = await env.LOOKUP_PER_IP.limit({ key: ip });
  if (!success) return json({ result: 'Too many requests: up to 30 lookups a minute (each can hold 100 numbers)' }, 429);

  // The number goes in the path; ?number= works too, for clients that build query strings.
  const path = url.pathname.slice('/v1/fleet'.length).replace(/^\/|\/$/g, '');
  let raw;
  try {
    raw = decodeURIComponent(path) || url.searchParams.get('number') || '';
  } catch {
    raw = path; // A stray % in the path: say it's not a number instead of failing.
  }
  if (!raw) return json({ result: USAGE }, 400);
  const parts = raw.split(',').map((p) => p.trim().replace(/^#/, '')).filter(Boolean);
  if (!parts.length || parts.some((p) => !/^\d{1,6}$/.test(p))) return json({ result: `Not a fleet number: ${raw}. ${USAGE}` }, 400);
  if (parts.length > MAX_NUMBERS) return json({ result: `Up to ${MAX_NUMBERS} numbers per call` }, 400);
  const typeParam = url.searchParams.get('type')?.toLowerCase() ?? null;
  const kind = typeParam === null ? null : TYPES[typeParam];
  if (kind === undefined) return json({ result: 'type must be bus or tram (or 1 or 2)' }, 400);

  const fleet = await load();
  if (!fleet) return json({ result: "The fleet data isn't available right now; try again in a few minutes" }, 503);

  if (!raw.includes(',')) {
    const hit = vehicle(fleet, Number(parts[0]), kind);
    if (!hit) return json({ result: `No ${kind?.toLowerCase() ?? 'bus or tram'} ${parts[0]} in Warsaw's fleet` }, 404);
    return found({ result: hit, fleetUpdated: fleet.fetched });
  }
  // Several: every number asked for is a key, null when it isn't in the fleet.
  const result = {};
  for (const p of parts) result[Number(p)] = vehicle(fleet, Number(p), kind);
  return found({ result, fleetUpdated: fleet.fetched });
}

async function load() {
  if (memo && Date.now() - memo.at < MEMORY_MS) return memo.fleet;
  try {
    const res = await fetch(FLEET, { cf: { cacheTtl: EDGE_SECONDS, cacheEverything: true } });
    if (!res.ok) throw new Error(`GitHub answered ${res.status}`);
    const fleet = await res.json();
    if (!Array.isArray(fleet?.models)) throw new Error('no models');
    memo = { at: Date.now(), fleet };
  } catch (e) {
    console.log(`fleet: ${e}`);
    // An old copy beats none; try GitHub again in a few minutes, not on every call.
    if (memo) memo.at = Date.now() - MEMORY_MS + 5 * 60_000;
  }
  return memo?.fleet ?? null;
}

/// The most likely vehicle with this number, with any others listing it, or null.
function vehicle(fleet, number, kind) {
  const [best, ...others] = find(fleet, number, kind);
  return best ? { ...best, otherMatches: others } : null;
}

/// Every model listing the number, most likely first, the way the app picks: regular stock
/// before preserved and test vehicles, then the bigger fleet.
export function find(fleet, number, kind) {
  const hits = [];
  for (const m of fleet.models) {
    if (kind && m.kind !== kind) continue;
    const batch = m.batches.find((b) => b.numbers.includes(number));
    if (batch) hits.push(describe(m, batch, number));
  }
  const special = (h) => (h.tier === 'VINTAGE' || h.tier === 'ON TEST' ? 1 : 0);
  return hits.sort((a, b) => special(a) - special(b) || b.fleetSize - a.fleetSize);
}

function describe(m, b, number) {
  // Some of a model's vehicles differ from the rest (fewer seats, another drive).
  const specs = m.variants?.find((v) => v.numbers.includes(number))?.specs ?? m.specs;
  return {
    number,
    type: m.kind.toLowerCase(),
    model: m.name,
    make: m.make,
    modelId: m.id,
    year: b.year ?? null,
    operator: b.operator,
    depot: b.depotName ? { code: b.depotCode || null, name: b.depotName } : null,
    tier: tier(m),
    specs: specs ? {
      lengthM: specs.length ? Math.round(specs.length / 10) / 100 : null,
      drive: specs.drive ?? null,
      seats: specs.seats ?? null,
      capacity: specs.places ?? null,
      airCon: specs.airCon ?? null,
      floor: FLOORS[specs.floor] ?? null,
    } : null,
    livery: m.liveries?.[number] ?? null,
    coupled: m.coupled === true,
    // The other car of a fixed pair (KMKM's 105Na 1000+1001, 13N 821+818).
    partner: m.sets?.find((pair) => pair.includes(number))?.find((n) => n !== number) ?? null,
    trial: m.onTest === true,
    // When it's on trial, until when, e.g. "ON TRIAL SEP–OCT 2026".
    trialLabel: m.onTest ? (m.trial ?? null) : null,
    fleetSize: m.fleet,
  };
}

// The app's Tier: by fleet size, except preserved and test vehicles.
function tier(m) {
  if (m.vintage) return 'VINTAGE';
  if (m.onTest) return 'ON TEST';
  return m.fleet <= 12 ? 'LEGENDARY' : m.fleet <= 48 ? 'GOLD' : m.fleet <= 80 ? 'RARE' : 'COMMON';
}

// It changes at most daily, so clients may keep an answer for an hour.
function found(obj) {
  return new Response(JSON.stringify(obj), {
    headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'public, max-age=3600' },
  });
}

function json(obj, status) {
  return new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' } });
}
