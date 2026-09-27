-- TABOR stats (D1). Apply with:
--   npx wrangler d1 execute tabor-stats --remote --file schema.sql
--
-- Sized for Cloudflare's free plan (100,000 rows written a day, 500 MB a database):
-- a sample is one row holding every vehicle out at that moment, not a row per vehicle,
-- and the nightly rollup boils each day down into the small tables below.
-- Kinds are the feed's types: 1 bus, 2 tram. Days and minutes are Warsaw wall-clock time.

-- One snapshot every 5 minutes, kept for four weeks.
-- v: [[number, kind, line, lat×1e4, lon×1e4], …], only rows fresher than 3 minutes.
-- ok: 1 buses answered, 2 trams answered, 3 both, 0 neither.
CREATE TABLE IF NOT EXISTS samples (
  ts INTEGER PRIMARY KEY,
  day TEXT NOT NULL,
  minute INTEGER NOT NULL,
  ok INTEGER NOT NULL,
  v TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS samples_day ON samples (day);

-- fleet.json, flattened; reloaded when its `fetched` date changes.
CREATE TABLE IF NOT EXISTS models (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind INTEGER NOT NULL,
  tier TEXT NOT NULL,
  fleet INTEGER NOT NULL
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS fleet (
  kind INTEGER NOT NULL,
  number INTEGER NOT NULL,
  model TEXT NOT NULL,
  year INTEGER,
  depot TEXT,
  PRIMARY KEY (kind, number)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY,
  value TEXT
) WITHOUT ROWID;

-- The rollup, one set of rows per day. Model and tier are copied in, so a vehicle keeps the
-- model it had that day, and the ones fleet.json doesn't know show up with model NULL.

CREATE TABLE IF NOT EXISTS days (
  day TEXT PRIMARY KEY,
  samples INTEGER NOT NULL,
  failed INTEGER NOT NULL,
  peak_out INTEGER NOT NULL,
  peak_minute INTEGER
) WITHOUT ROWID;

-- Samples per hour, to turn vehicle-samples into "vehicles out on average".
CREATE TABLE IF NOT EXISTS day_hour (
  day TEXT NOT NULL,
  hour INTEGER NOT NULL,
  samples INTEGER NOT NULL,
  PRIMARY KEY (day, hour)
) WITHOUT ROWID;

-- samples: how many snapshots it was in; first/last: minutes after midnight.
CREATE TABLE IF NOT EXISTS vehicle_day (
  day TEXT NOT NULL,
  kind INTEGER NOT NULL,
  number INTEGER NOT NULL,
  model TEXT,
  tier TEXT,
  samples INTEGER NOT NULL,
  first INTEGER NOT NULL,
  last INTEGER NOT NULL,
  lines TEXT,
  PRIMARY KEY (day, kind, number)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS tier_hour (
  day TEXT NOT NULL,
  kind INTEGER NOT NULL,
  tier TEXT NOT NULL,
  hour INTEGER NOT NULL,
  vsamples INTEGER NOT NULL,
  PRIMARY KEY (day, kind, tier, hour)
) WITHOUT ROWID;

-- Keyed by model first, for one model's hours without reading every model's.
CREATE TABLE IF NOT EXISTS model_hour (
  model TEXT NOT NULL,
  day TEXT NOT NULL,
  hour INTEGER NOT NULL,
  vsamples INTEGER NOT NULL,
  PRIMARY KEY (model, day, hour)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS line_day (
  day TEXT NOT NULL,
  line TEXT NOT NULL,
  model TEXT NOT NULL,
  vehicles INTEGER NOT NULL,
  vsamples INTEGER NOT NULL,
  PRIMARY KEY (day, line, model)
) WITHOUT ROWID;

-- The map: ~1 km cells (0.01° of latitude by 0.015° of longitude).
CREATE TABLE IF NOT EXISTS cell_day (
  day TEXT NOT NULL,
  tier TEXT NOT NULL,
  lat INTEGER NOT NULL,
  lon INTEGER NOT NULL,
  vsamples INTEGER NOT NULL,
  PRIMARY KEY (day, tier, lat, lon)
) WITHOUT ROWID;

-- Per day, from vehicle_day: small enough to read months of.
CREATE TABLE IF NOT EXISTS tier_day (
  day TEXT NOT NULL,
  kind INTEGER NOT NULL,
  tier TEXT NOT NULL,
  vehicles INTEGER NOT NULL,
  vsamples INTEGER NOT NULL,
  PRIMARY KEY (day, kind, tier)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS model_day (
  day TEXT NOT NULL,
  model TEXT NOT NULL,
  vehicles INTEGER NOT NULL,
  vsamples INTEGER NOT NULL,
  PRIMARY KEY (day, model)
) WITHOUT ROWID;
