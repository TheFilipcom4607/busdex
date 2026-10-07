// The arithmetic behind tracking (track.js), kept apart from the Durable Object so it can be
// tested with plain Node: `node src/trackgeo.test.mjs`.

/// The vehicle's row in the city's feed, without parsing the whole 180 KB of it.
export function findVehicle(text, number) {
  const re = new RegExp(`"VehicleNumber"\\s*:\\s*"${number}"`, 'g');
  let best = null;
  for (let m; (m = re.exec(text)); ) {
    const start = text.lastIndexOf('{', m.index);
    const end = text.indexOf('}', m.index);
    if (start < 0 || end < 0) continue;
    try {
      const row = JSON.parse(text.slice(start, end + 1));
      if (!best || String(row.Time) > String(best.Time)) best = row;
    } catch {}
  }
  return best;
}

// The same flat-map arithmetic as the app's RouteShape.

const M_PER_DEG = (6371 * 1000 * Math.PI) / 180;

export function geometry(f) {
  const points = decodePolyline(f.path);
  const [lat0, lon0] = points[0];
  const k = Math.cos((lat0 * Math.PI) / 180);
  const xy = points.map(([lat, lon]) => [(lon - lon0) * k * M_PER_DEG, (lat - lat0) * M_PER_DEG]);
  const cum = [0];
  for (let i = 1; i < points.length; i++) cum.push(cum[i - 1] + haversine(points[i - 1], points[i]));
  return { lat0, lon0, k, xy, cum };
}

/// The closest point on the route to p within [from, to] metres along it: { along, offset }.
export function project(g, [lat, lon], [from, to] = [-Infinity, Infinity]) {
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  const px = (lon - g.lon0) * g.k * M_PER_DEG, py = (lat - g.lat0) * M_PER_DEG;
  let best = null;
  for (let i = 0; i < g.xy.length - 1; i++) {
    if (g.cum[i + 1] < from || g.cum[i] > to) continue;
    const [ax, ay] = g.xy[i], [bx, by] = g.xy[i + 1];
    const dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
    let t = len2 === 0 ? 0 : Math.min(1, Math.max(0, ((px - ax) * dx + (py - ay) * dy) / len2));
    let along = g.cum[i] + t * (g.cum[i + 1] - g.cum[i]);
    if (along < from || along > to) {
      along = Math.min(Math.max(along, from), to);
      const span = g.cum[i + 1] - g.cum[i];
      t = span > 0 ? (along - g.cum[i]) / span : 0;
    }
    const cx = ax + t * dx, cy = ay + t * dy;
    const offset = Math.hypot(px - cx, py - cy);
    if (!best || offset < best.offset) best = { along, offset };
  }
  return best;
}

function haversine([lat1, lon1], [lat2, lon2]) {
  const r = Math.PI / 180;
  const dLat = (lat2 - lat1) * r, dLon = (lon2 - lon1) * r;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * r) * Math.cos(lat2 * r) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371 * 1000 * Math.asin(Math.min(1, Math.sqrt(h)));
}

/// Google's encoded polyline format, 5 decimal places, as the app's Polyline writes it.
export function decodePolyline(s) {
  const out = [];
  let lat = 0, lon = 0, i = 0;
  const next = () => {
    let result = 0, shift = 0, b;
    do {
      if (i >= s.length) return null;
      b = s.charCodeAt(i++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    return result & 1 ? ~(result >> 1) : result >> 1;
  };
  while (i < s.length) {
    const dLat = next(), dLon = next();
    if (dLat === null || dLon === null) break;
    lat += dLat;
    lon += dLon;
    out.push([lat / 1e5, lon / 1e5]);
  }
  return out;
}

