// node src/trackgeo.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decodePolyline, findVehicle, geometry, project } from './trackgeo.js';

// Google's own polyline example.
const pts = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
assert.equal(pts.length, 3);
assert.ok(Math.abs(pts[0][0] - 38.5) < 1e-9 && Math.abs(pts[2][1] + 126.453) < 1e-9);

// A straight street east along 52.23, 0.03° long (about 2 km): encode it the app's way.
function encode(points) {
  let out = '', pLat = 0, pLon = 0;
  const put = (d) => { let v = d < 0 ? ~(d << 1) : d << 1; while (v >= 0x20) { out += String.fromCharCode((0x20 | (v & 0x1f)) + 63); v >>= 5; } out += String.fromCharCode(v + 63); };
  for (const [lat, lon] of points) { const a = Math.round(lat * 1e5), b = Math.round(lon * 1e5); put(a - pLat); put(b - pLon); pLat = a; pLon = b; }
  return out;
}
const street = Array.from({ length: 61 }, (_, i) => [52.23, 21.0 + i * 0.0005]);
const g = geometry({ path: encode(street) });
assert.ok(Math.abs(g.cum.at(-1) - 2046) < 5, `length ${g.cum.at(-1)}`);
const mid = project(g, [52.2302, 21.015]);
assert.ok(Math.abs(mid.along - 1023) < 3 && Math.abs(mid.offset - 22) < 2, JSON.stringify(mid));
// Inside a window, the closest point within it.
const clamped = project(g, [52.23, 21.025], [0, 500]);
assert.ok(Math.abs(clamped.along - 500) < 1e-6 && clamped.offset > 1000);

// Finding one vehicle in a feed without parsing all of it, freshest row first.
const feed = readFileSync(new URL('../../Tests/Fixtures/live-buses.json', import.meta.url), 'utf8');
const row = findVehicle(feed, '1003');
assert.equal(row.Lines, '219');
assert.equal(findVehicle(feed, '99999'), null);
const twice = '[{"VehicleNumber":"5","Time":"2026-10-04 10:00:00","Lat":1},{"Lat":2,"VehicleNumber" : "5","Time":"2026-10-04 10:00:09"}]';
assert.equal(findVehicle(twice, '5').Lat, 2);
assert.equal(findVehicle(twice, '50'), null);
console.log('trackgeo: ok');
