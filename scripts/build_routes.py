#!/usr/bin/env python3
"""Build build/routes.json from ZTM's official GTFS (https://gtfs.ztm.waw.pl/last/): the street
shape of every bus and tram route variant, how many trips run it, and its stops in order, so
HUNT can draw where a vehicle goes next.

The feed is a 52 MB zip holding a 380 MB stop_times.txt; it's read straight from the zip,
never extracted. The feed repeats every route and trip once per day it covers (ids start
"0_", "1_", …); trips are counted for today and tomorrow only, so a weekend detour doesn't
outweigh the usual way.

Usage:  python3 scripts/build_routes.py              # download and build
        python3 scripts/build_routes.py gtfs.zip     # from a zip already on disk
"""
import csv
import gzip
import io
import json
import math
import os
import sys
import urllib.request
import zipfile
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "routes.json"
URL = "https://gtfs.ztm.waw.pl/last/"
# GTFS route_type: 0 tram, 3 bus. Rail (2: WKD, KM, SKM) and the metro stay out.
KINDS = {"0": "TRAM", "3": "BUS"}
# How far a stop may sit from its shape and still be put on it. Stops sit at the kerb or on
# an island, a few metres off the road's centreline.
STOP_SNAP = 400


def download():
    # GitHub's runners can't reach ZTM, so the Action goes through the tabor-live Worker
    # (GTFS_URL, with the upload token).
    url = os.environ.get("GTFS_URL", URL)
    headers = {"User-Agent": "tabor-routes/1"}
    if url != URL and os.environ.get("ROUTES_UPLOAD_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['ROUTES_UPLOAD_TOKEN']}"
    print(f"downloading {url}", file=sys.stderr)
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=300) as r:
        return io.BytesIO(r.read())


def rows(z, name):
    # utf-8-sig: every file starts with a byte-order mark.
    with z.open(name) as f:
        yield from csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig", newline=""))


def metres(a, b):
    """Haversine, as Geo.km in the app, so distances along a shape agree on both sides."""
    r = 6371.0 * 1000
    la1, la2 = math.radians(a[0]), math.radians(b[0])
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin(math.radians(b[1] - a[1]) / 2) ** 2
    return 2 * r * math.asin(min(1, math.sqrt(h)))


def encode(points):
    """Google's encoded polyline, 5 decimal places."""
    out, plat, plon = [], 0, 0
    for lat, lon in points:
        ilat, ilon = round(lat * 1e5), round(lon * 1e5)
        for d in (ilat - plat, ilon - plon):
            v = ~(d << 1) if d < 0 else d << 1
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1F)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        plat, plon = ilat, ilon
    return "".join(out)


def project(p, a, b):
    """Where p falls on segment a-b: (fraction 0…1, metres off it). Flat projection, fine for
    segments of tens of metres."""
    k = math.cos(math.radians(a[0]))
    ax, ay, bx, by, px, py = a[1] * k, a[0], b[1] * k, b[0], p[1] * k, p[0]
    dx, dy = bx - ax, by - ay
    t = 0 if dx == dy == 0 else max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return t, metres(p, (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))


def place_stops(path, cumulative, stops):
    """Metres along the shape for each stop, never going backwards: a loop passes the same
    corner twice, and the stop belongs to the pass that comes next."""
    out, floor, start = [], 0.0, 0
    for name, lat, lon in stops:
        best = None
        for i in range(start, len(path) - 1):
            t, off = project((lat, lon), path[i], path[i + 1])
            along = cumulative[i] + t * (cumulative[i + 1] - cumulative[i])
            if along < floor:
                continue
            # The first good fit going forward: past it, a later pass could fit better and
            # skip the stretch in between.
            if best is None or off < best[1]:
                best = (along, off, i)
            elif best[1] < 25 and along - best[0] > 300:
                break
        if best is None or best[1] > STOP_SNAP:
            continue
        floor, start = best[0], best[2]
        out.append([name, round(lat, 5), round(lon, 5), round(best[0])])
    return out


def active_days(z, today):
    """Day prefixes ("0", "1", …) of services running today or tomorrow."""
    wanted = {today.strftime("%Y%m%d"), (today + timedelta(days=1)).strftime("%Y%m%d")}
    days = set()
    for r in rows(z, "calendar.txt"):
        if any(r["start_date"] <= d <= r["end_date"] for d in wanted):
            days.add(r["service_id"].split("_")[0])
    # A feed that's gone stale: its first day is the best guess there is.
    return days or {"0"}


def build(z, today=None):
    today = today or date.today()
    feed = next(rows(z, "feed_info.txt"))["feed_version"]
    days = active_days(z, today)

    lines = {}
    for r in rows(z, "routes.txt"):
        if r["route_type"] in KINDS:
            lines[r["route_id"]] = (r["route_short_name"], KINDS[r["route_type"]])

    # How many trips run each shape (today and tomorrow), and one trip to read its stops from.
    trips = defaultdict(int)
    shape_line = {}
    sample = {}
    for r in rows(z, "trips.txt"):
        line = lines.get(r["route_id"])
        if not line or not r["shape_id"]:
            continue
        shape = r["shape_id"]
        shape_line[shape] = line
        if r["route_id"].split("_")[0] in days:
            trips[shape] += 1
        sample.setdefault(shape, r["trip_id"])

    paths = defaultdict(list)
    for r in rows(z, "shapes.txt"):
        if r["shape_id"] in shape_line:
            paths[r["shape_id"]].append((int(r["shape_pt_sequence"]), float(r["shape_pt_lat"]), float(r["shape_pt_lon"])))

    stop_names = {r["stop_id"]: (r["stop_name"], float(r["stop_lat"]), float(r["stop_lon"])) for r in rows(z, "stops.txt")}

    # The big one: only the sample trips' rows are parsed; the trip id is checked on the raw
    # line first, which skips the csv module for the other 99%.
    wanted = {t: s for s, t in sample.items()}
    stop_seq = defaultdict(list)
    with z.open("stop_times.txt") as f:
        text = io.TextIOWrapper(f, encoding="utf-8-sig", newline="")
        header = next(csv.reader([text.readline()]))
        col = {name: i for i, name in enumerate(header)}
        for raw in text:
            trip = raw[:raw.index(",")]
            if trip not in wanted:
                continue
            r = next(csv.reader([raw]))
            stop_seq[wanted[trip]].append((int(r[col["stop_sequence"]]), r[col["stop_id"]]))

    out = defaultdict(lambda: {"kind": None, "shapes": {}})
    for shape, pts in paths.items():
        if not trips[shape]:
            continue  # Runs on other days only.
        line, kind = shape_line[shape]
        pts.sort()
        path = [(round(lat, 5), round(lon, 5)) for _, lat, lon in pts]
        path = [p for i, p in enumerate(path) if i == 0 or p != path[i - 1]]
        if len(path) < 2:
            continue
        encoded = encode(path)
        entry = out[line]
        entry["kind"] = kind
        # Route variants that share a street shape (a short working, a different depot run)
        # are one shape here, with their trips added up.
        if encoded in entry["shapes"]:
            entry["shapes"][encoded]["trips"] += trips[shape]
            continue
        cumulative = [0.0]
        for a, b in zip(path, path[1:]):
            cumulative.append(cumulative[-1] + metres(a, b))
        stops = [stop_names[s] for _, s in sorted(stop_seq[shape]) if s in stop_names]
        entry["shapes"][encoded] = {
            "id": shape, "trips": trips[shape], "path": encoded,
            "stops": place_stops(path, cumulative, stops),
        }

    result = {
        "feed": feed,
        "built": today.isoformat(),
        "lines": {
            line: {"kind": e["kind"], "shapes": sorted(e["shapes"].values(), key=lambda s: -s["trips"])}
            for line, e in sorted(out.items())
        },
    }
    return result


if __name__ == "__main__":
    source = open(sys.argv[1], "rb") if len(sys.argv) > 1 else download()
    with zipfile.ZipFile(source) as z:
        result = build(z)
    OUT.parent.mkdir(exist_ok=True)
    body = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode()
    OUT.write_bytes(body)
    shapes = sum(len(l["shapes"]) for l in result["lines"].values())
    print(f"wrote {OUT.relative_to(ROOT)}: {len(result['lines'])} lines, {shapes} shapes, "
          f"{len(body) / 1e6:.1f} MB, {len(gzip.compress(body)) / 1e6:.2f} MB gzipped ({result['feed']})")
