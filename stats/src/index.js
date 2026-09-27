// TABOR's fleet stats: what Warsaw's buses and trams actually do, from the same live feed
// the app uses. Built to stay on Cloudflare's free plan (see schema.sql for the budget).
//
//   every 5 min   save a snapshot of every vehicle out (one row)
//   01:30 UTC     roll finished days up into the small per-day tables, drop old snapshots
//   GET /         the dashboard (dashboard.html)
//   GET /api/*    its data, behind the STATS_KEY secret
//
// The city's feed doesn't answer from abroad, and cron runs wherever Cloudflare has room.
// Placement (wrangler.toml) pins only fetch handlers to Warsaw, so the cron calls this
// Worker's own fetch handler through the SELF binding, and the jobs run there.

import { fetchCity } from '../../proxy/src/city.js';
import DASHBOARD from './dashboard.html';

const FLEET_URL = 'https://raw.githubusercontent.com/TheFilipcom4607/busdex/main/Tabor/Resources/fleet.json';
const ROLLUP_CRON = '30 1 * * *';
// The feed keeps some vehicles' last position for years; the app ignores anything older.
const MAX_AGE_MS = 180_000;
// Every snapshot row: [number, kind, line, lat×1e4, lon×1e4].
// Snapshots are ~25 KB each; four weeks of them stay well under the free plan's 500 MB.
const KEEP_SAMPLE_DAYS = 28;

// "2026-09-27 13:02:56", Warsaw wall-clock time, the same format the feed uses. Worked out
// by hand: Intl's time zone data costs milliseconds, and the free plan allows 10 per run.
// Summer time runs from 01:00 UTC on the last Sunday of March to the last Sunday of October.
function warsaw(date) {
  const y = date.getUTCFullYear();
  const lastSunday = (month) => {
    const d = new Date(Date.UTC(y, month + 1, 0, 1));
    return d.getTime() - d.getUTCDay() * 86_400_000;
  };
  const summer = date >= lastSunday(2) && date < lastSunday(9);
  return new Date(date.getTime() + (summer ? 2 : 1) * 3_600_000).toISOString().replace('T', ' ').slice(0, 19);
}
const daysBefore = (day, n) => new Date(Date.parse(day) - n * 86_400_000).toISOString().slice(0, 10);

const JOBS = { '/jobs/sample': sample, '/jobs/nightly': nightly };

export default {
  async scheduled(event, env, ctx) {
    const job = event.cron === ROLLUP_CRON ? '/jobs/nightly' : '/jobs/sample';
    const res = await env.SELF.fetch(`https://tabor-stats${job}`, { method: 'POST', headers: { Authorization: `Bearer ${env.STATS_KEY}` } });
    if (!res.ok) throw new Error(`${job}: ${res.status} ${await res.text()}`);
  },

  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const job = JOBS[url.pathname];
    if (job) {
      if (request.method !== 'POST' || !authorized(request, env)) return json({ error: 'Not found' }, 404);
      return json(await job(env));
    }
    if (request.method !== 'GET') return json({ error: 'GET only' }, 405);
    if (url.pathname === '/') {
      return new Response(DASHBOARD, { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' } });
    }
    const handler = API[url.pathname];
    if (!handler) return json({ error: 'Not found' }, 404);
    if (!authorized(request, env)) return json({ error: 'Wrong key' }, 401);

    // History only changes at night and live data every 5 minutes, so repeat visits are
    // served from Cloudflare's cache instead of reading the database again.
    const cache = caches.default;
    const key = new Request(`https://cache.tabor-stats${url.pathname}${url.search}`);
    const hit = await cache.match(key);
    if (hit) return hit;
    const { body, seconds } = await handler(env, url.searchParams);
    const response = json(body, 200, seconds);
    ctx.waitUntil(cache.put(key, response.clone()));
    return response;
  },
};

function authorized(request, env) {
  const given = (request.headers.get('Authorization') ?? '').replace(/^Bearer /, '');
  const want = env.STATS_KEY ?? '';
  if (!want || given.length !== want.length) return false;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= given.charCodeAt(i) ^ want.charCodeAt(i);
  return diff === 0;
}

// MARK: - Collecting

// SQLite unpacks the city's ~250 KB replies, so the Worker never parses them: its own CPU
// time is capped at 10 ms a run on the free plan.
const SAMPLE = `
  WITH raw AS (
    SELECT 1 AS kind, j.value AS r FROM json_each(CASE WHEN json_valid(?1) THEN ?1 ELSE '[]' END, ?2) j
    UNION ALL
    SELECT 2, j.value FROM json_each(CASE WHEN json_valid(?3) THEN ?3 ELSE '[]' END, ?4) j),
  fresh AS (
    SELECT kind, CAST(r->>'VehicleNumber' AS INTEGER) AS number, trim(coalesce(r->>'Lines', '')) AS line,
           CAST(round((r->>'Lat') * 10000) AS INTEGER) AS lat, CAST(round((r->>'Lon') * 10000) AS INTEGER) AS lon,
           r->>'Time' AS time
    FROM raw
    WHERE r->>'Time' >= ?5 AND CAST(r->>'VehicleNumber' AS INTEGER) > 0
      AND CAST(r->>'VehicleNumber' AS INTEGER) || '' = r->>'VehicleNumber'),
  -- A vehicle now and then appears twice; SQLite takes the other columns from its newest row.
  live AS (SELECT kind, number, line, lat, lon, max(time) FROM fresh WHERE lat AND lon GROUP BY kind, number)
  INSERT OR REPLACE INTO samples (ts, day, minute, ok, v)
  SELECT ?6, ?7, ?8,
         -- A list with nothing live in it means that part of the feed has stalled.
         (EXISTS (SELECT 1 FROM live WHERE kind = 1)) | ((EXISTS (SELECT 1 FROM live WHERE kind = 2)) << 1),
         coalesce((SELECT json_group_array(json_array(number, kind, line, lat, lon)) FROM live), '[]')
  RETURNING ok, json_array_length(v) AS vehicles`;

async function sample(env) {
  await ensureFleet(env);
  const now = new Date();
  const local = warsaw(now);
  const [buses, trams] = await Promise.all([fetchCity(1, env), fetchCity(2, env)]);
  const minute = +local.slice(11, 13) * 60 + +local.slice(14, 16);
  const result = await env.DB.prepare(SAMPLE).bind(
    buses?.text ?? '[]', buses?.path ?? '$', trams?.text ?? '[]', trams?.path ?? '$',
    warsaw(new Date(now - MAX_AGE_MS)), Math.floor(now / 1000), local.slice(0, 10), minute,
  ).first();
  if (result.ok !== 3) console.log(`sample ${local}: ${result.ok === 0 ? 'no answer' : result.ok === 1 ? 'no trams' : 'no buses'}`);
  return { local, ...result, sources: [buses?.source, trams?.source] };
}

// fleet.json says which model each number is; reloaded whenever it changes on GitHub.
// SQLite unpacks it, which keeps the Worker's own CPU time (10 ms on the free plan) free.
async function ensureFleet(env, check = false) {
  const stored = await env.DB.prepare("SELECT value FROM meta WHERE key = 'fleet'").first('value');
  if (stored && !check) return;
  const res = await fetch(FLEET_URL, { signal: AbortSignal.timeout(10_000) });
  if (!res.ok) return;
  const text = await res.text();
  const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-1', new TextEncoder().encode(text)))]
    .map((b) => b.toString(16).padStart(2, '0')).join('');
  if (hash === stored) return;
  const db = env.DB;
  const kind = "CASE m.value->>'kind' WHEN 'TRAM' THEN 2 ELSE 1 END";
  await db.batch([
    db.prepare('DELETE FROM models'),
    db.prepare('DELETE FROM fleet'),
    // The app's Tier.of, plus its two tiers that don't go by size.
    db.prepare(`INSERT OR IGNORE INTO models
      SELECT m.value->>'id', m.value->>'name', ${kind},
             CASE WHEN m.value->>'vintage' THEN 'VINTAGE' WHEN m.value->>'onTest' THEN 'ON TEST'
                  WHEN m.value->>'fleet' <= 12 THEN 'LEGENDARY' WHEN m.value->>'fleet' <= 48 THEN 'GOLD'
                  WHEN m.value->>'fleet' <= 80 THEN 'RARE' ELSE 'COMMON' END,
             m.value->>'fleet'
      FROM json_each(?1, '$.models') m`).bind(text),
    db.prepare(`INSERT OR IGNORE INTO fleet
      SELECT ${kind}, n.value, m.value->>'id', b.value->>'year', nullif(b.value->>'depotName', '')
      FROM json_each(?1, '$.models') m, json_each(m.value, '$.batches') b, json_each(b.value, '$.numbers') n`).bind(text),
    db.prepare("INSERT OR REPLACE INTO meta VALUES ('fleet', ?1), ('fleet_fetched', json_extract(?2, '$.fetched'))").bind(hash, text),
  ]);
  console.log('fleet reloaded');
}

// MARK: - Nightly rollup

async function nightly(env) {
  await ensureFleet(env, true);
  const today = warsaw(new Date()).slice(0, 10);
  // Catches up on any day a failed night missed, a few at a time.
  const { results } = await env.DB.prepare(
    'SELECT DISTINCT day FROM samples WHERE day < ? AND day NOT IN (SELECT day FROM days) ORDER BY day LIMIT 3',
  ).bind(today).all();
  for (const { day } of results) await rollup(env, day);
  await env.DB.prepare('DELETE FROM samples WHERE day < ?').bind(daysBefore(today, KEEP_SAMPLE_DAYS)).run();
  return { rolled: results.map((r) => r.day) };
}

// Every vehicle in every good snapshot of the day. Snapshots missing buses or trams would
// skew the hourly averages, so they only count toward the failure rate.
const EXPAND = `x AS (
  SELECT s.minute AS minute, j.value->>0 AS number, j.value->>1 AS kind, j.value->>2 AS line,
         j.value->>3 AS lat, j.value->>4 AS lon
  FROM samples s, json_each(s.v) j WHERE s.day = ?1 AND s.ok = 3)`;
// Grouped before joining, so each lookup covers a vehicle's hour (or line, or cell), not
// every snapshot: D1 counts every row it reads.
const VD = 'JOIN vehicle_day vd ON vd.day = ?1 AND vd.kind = g.kind AND vd.number = g.number';

async function rollup(env, day) {
  const db = env.DB;
  const q = (sql) => db.prepare(sql).bind(day);
  await db.batch([
    ...['days', 'day_hour', 'vehicle_day', 'tier_hour', 'model_hour', 'line_day', 'cell_day', 'tier_day', 'model_day']
      .map((t) => q(`DELETE FROM ${t} WHERE day = ?1`)),
    q(`INSERT INTO days (day, samples, failed, peak_out, peak_minute)
       SELECT ?1, sum(ok = 3), sum(ok <> 3), coalesce(max(CASE WHEN ok = 3 THEN json_array_length(v) END), 0),
              (SELECT minute FROM samples WHERE day = ?1 AND ok = 3 ORDER BY json_array_length(v) DESC LIMIT 1)
       FROM samples WHERE day = ?1`),
    q(`INSERT INTO day_hour SELECT ?1, minute / 60, count(*) FROM samples WHERE day = ?1 AND ok = 3 GROUP BY 2`),
    q(`WITH ${EXPAND},
       v AS (SELECT kind, number, count(*) n, min(minute) a, max(minute) b, group_concat(DISTINCT line) lines
             FROM x GROUP BY kind, number)
       INSERT INTO vehicle_day (day, kind, number, model, tier, samples, first, last, lines)
       SELECT ?1, v.kind, v.number, f.model, m.tier, v.n, v.a, v.b, v.lines
       FROM v LEFT JOIN fleet f ON f.kind = v.kind AND f.number = v.number LEFT JOIN models m ON m.id = f.model`),
    q(`INSERT INTO tier_day SELECT ?1, kind, coalesce(tier, 'UNKNOWN'), count(*), sum(samples)
       FROM vehicle_day WHERE day = ?1 GROUP BY kind, 3`),
    q(`INSERT INTO model_day SELECT ?1, model, count(*), sum(samples)
       FROM vehicle_day WHERE day = ?1 AND model IS NOT NULL GROUP BY model`),
    q(`WITH ${EXPAND}, g AS (SELECT kind, number, minute / 60 AS hour, count(*) n FROM x GROUP BY 1, 2, 3)
       INSERT INTO tier_hour SELECT ?1, g.kind, coalesce(vd.tier, 'UNKNOWN'), g.hour, sum(g.n) FROM g ${VD} GROUP BY 2, 3, 4`),
    q(`WITH ${EXPAND}, g AS (SELECT kind, number, minute / 60 AS hour, count(*) n FROM x GROUP BY 1, 2, 3)
       INSERT INTO model_hour SELECT vd.model, ?1, g.hour, sum(g.n) FROM g ${VD} WHERE vd.model IS NOT NULL GROUP BY 1, 3`),
    q(`WITH ${EXPAND}, g AS (SELECT line, kind, number, count(*) n FROM x WHERE line <> '' GROUP BY 1, 2, 3)
       INSERT INTO line_day SELECT ?1, g.line, vd.model, count(*), sum(g.n) FROM g ${VD} WHERE vd.model IS NOT NULL GROUP BY 2, 3`),
    q(`WITH ${EXPAND}, g AS (SELECT kind, number, lat / 100 AS la, lon / 150 AS lo, count(*) n FROM x GROUP BY 1, 2, 3, 4)
       INSERT INTO cell_day SELECT ?1, coalesce(vd.tier, 'UNKNOWN'), g.la, g.lo, sum(g.n) FROM g ${VD} GROUP BY 2, 3, 4`),
  ]);
  console.log(`rolled up ${day}`);
}

// MARK: - API

// SQLite builds each list as JSON text, and the Worker only glues the pieces together:
// decoding and re-encoding thousands of rows would eat its 10 ms.
const list = (db, columns, from, ...binds) =>
  db.prepare(`SELECT coalesce(json_group_array(json_array(${columns})), '[]') AS j FROM (${from})`).bind(...binds).first('j');
const since = (params) => {
  const days = Math.max(0, Math.min(3650, Number(params.get('days')) || 0));
  return days ? daysBefore(warsaw(new Date()).slice(0, 10), days) : '0000';
};
const TODAY_X = `SELECT s.minute m, j.value->>0 n, j.value->>1 k, j.value->>2 l
                 FROM samples s, json_each(s.v) j WHERE s.day = ?1 AND s.ok = 3`;

const API = {
  // The newest snapshot and today so far.
  async '/api/live'(env) {
    const today = warsaw(new Date()).slice(0, 10);
    const db = env.DB;
    const [latest, vehicles, curve, counts] = await Promise.all([
      db.prepare('SELECT ts, minute, v FROM samples ORDER BY ts DESC LIMIT 1').first(),
      list(db, 'k, n, c, a, b, lines',
        `SELECT k, n, count(*) c, min(m) a, max(m) b, group_concat(DISTINCT l) lines FROM (${TODAY_X}) GROUP BY k, n`, today),
      list(db, 'minute, ok, b, t',
        `SELECT s.minute, s.ok, sum(j.value->>1 = 1) b, sum(j.value->>1 = 2) t
         FROM samples s LEFT JOIN json_each(s.v) j WHERE s.day = ?1 GROUP BY s.ts ORDER BY s.ts`, today),
      db.prepare('SELECT count(*) n, coalesce(sum(ok = 3), 0) good FROM samples WHERE day = ?1').bind(today).first(),
    ]);
    const latestJson = latest ? `{"ts":${latest.ts},"minute":${latest.minute},"v":${latest.v}}` : 'null';
    return {
      seconds: 60,
      body: `{"today":"${today}","latest":${latestJson},"vehicles":${vehicles},"curve":${curve},"samples":${counts.n},"good":${counts.good}}`,
    };
  },

  // Everything rolled up since `days` ago (0: all of it).
  async '/api/history'(env, params) {
    const from = since(params);
    const db = env.DB;
    const parts = {
      days: list(db, 'day, samples, failed, peak_out, peak_minute', 'SELECT * FROM days WHERE day >= ?1 ORDER BY day', from),
      tierDay: list(db, 'day, kind, tier, vehicles, vsamples', 'SELECT * FROM tier_day WHERE day >= ?1', from),
      // By weekday (0 Sunday) and hour, summed: "when are they out".
      weekTier: list(db, 'wd, kind, tier, hour, vs', `SELECT CAST(strftime('%w', day) AS INT) wd, kind, tier, hour, sum(vsamples) vs
        FROM tier_hour WHERE day >= ?1 GROUP BY 1, 2, 3, 4`, from),
      weekSamples: list(db, 'wd, hour, n', `SELECT CAST(strftime('%w', day) AS INT) wd, hour, sum(samples) n
        FROM day_hour WHERE day >= ?1 GROUP BY 1, 2`, from),
      modelDay: list(db, 'day, model, vehicles, vsamples', 'SELECT * FROM model_day WHERE day >= ?1', from),
      lines: list(db, 'line, model, vd, vs, days', `SELECT line, model, sum(vehicles) vd, sum(vsamples) vs, count(*) days
        FROM line_day WHERE day >= ?1 GROUP BY 1, 2`, from),
      cells: list(db, 'tier, lat, lon, vs', 'SELECT tier, lat, lon, sum(vsamples) vs FROM cell_day WHERE day >= ?1 GROUP BY 1, 2, 3', from),
      vehicles: list(db, 'kind, number, model, tier, d, s, span, lines, first, last',
        `SELECT kind, number, model, tier, count(*) d, sum(samples) s, max(last - first) span,
                group_concat(DISTINCT lines) lines, min(day) first, max(day) last
         FROM vehicle_day WHERE day >= ?1 GROUP BY kind, number`, from),
    };
    const done = await Promise.all(Object.values(parts));
    const body = Object.keys(parts).map((k, i) => `"${k}":${done[i]}`).join(',');
    return { seconds: 1800, body: `{"from":"${from}",${body}}` };
  },

  // One model's week, by weekday and hour.
  async '/api/model'(env, params) {
    const hours = await list(env.DB, 'wd, hour, vs', `SELECT CAST(strftime('%w', day) AS INT) wd, hour, sum(vsamples) vs
      FROM model_hour WHERE model = ?1 AND day >= ?2 GROUP BY 1, 2`, params.get('id') ?? '', since(params));
    return { seconds: 1800, body: `{"hours":${hours}}` };
  },

  // The catalogue the numbers are matched against, and how the collector is doing.
  async '/api/fleet'(env) {
    const db = env.DB;
    const [models, fleet, meta, span] = await Promise.all([
      list(db, 'id, name, kind, tier, fleet', 'SELECT * FROM models'),
      list(db, 'kind, number, model, year, depot', 'SELECT * FROM fleet'),
      db.prepare("SELECT json_group_object(key, value) j FROM meta").first('j'),
      db.prepare(`SELECT (SELECT min(day) FROM samples) first_sample, (SELECT count(*) FROM samples) samples,
                         (SELECT count(*) FROM days) days`).all(),
    ]);
    const extra = { ...span.results[0], dbBytes: span.meta?.size_after ?? null };
    return { seconds: 600, body: `{"models":${models},"fleet":${fleet},"meta":${meta},${JSON.stringify(extra).slice(1)}` };
  },
};

function json(obj, status = 200, seconds = 0) {
  return new Response(typeof obj === 'string' ? obj : JSON.stringify(obj), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': seconds ? `max-age=${seconds}` : 'no-store',
    },
  });
}
