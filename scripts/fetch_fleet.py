#!/usr/bin/env python3
"""Snapshot Warsaw's bus + tram fleet from the official ZTM vehicle database
(https://www.ztm.waw.pl/baza-danych-pojazdow/) into Tabor/Resources/fleet.json.

The list view has number, make, model, operator and depot but no year, so we
query it once per (traction, production year) and read the year from the filter.
A final unfiltered pass catches vehicles with no year on record.

Usage:  python3 scripts/fetch_fleet.py            # scrape + build
        python3 scripts/fetch_fleet.py --offline  # rebuild from data/ztm-vehicles.json
"""
import html
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "ztm-vehicles.json"
OUT = ROOT / "Tabor" / "Resources" / "fleet.json"
BASE = "https://www.ztm.waw.pl/baza-danych-pojazdow/"
# CloudFront rejects non-browser user agents.
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
    "Accept": "text/html",
    "Accept-Language": "pl,en;q=0.8",
}
TRACTIONS = {"1": "BUS", "4": "TRAM"}
DELAY = 0.5

ROW = re.compile(r'<a href="([^"]+)" class="grid-row-active" role="row">(.*?)</a>', re.S)
CELL = re.compile(r'<div role="cell"[^>]*>(.*?)</div>', re.S)


def get(url):
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read().decode("utf-8")
        except Exception as e:  # noqa: BLE001 — retry anything transient
            wait = 2 ** attempt
            print(f"  ! {e} — retry in {wait}s", file=sys.stderr)
            time.sleep(wait)
    raise RuntimeError(f"giving up on {url}")


def page_url(page, params):
    path = BASE if page == 1 else f"{BASE}page/{page}/"
    return path + "?" + urllib.parse.urlencode(params)


def scrape_list(params):
    """All rows for one filter combination, following pagination."""
    rows, page = [], 1
    while True:
        body = get(page_url(page, params))
        time.sleep(DELAY)
        found = ROW.findall(body)
        for href, inner in found:
            cells = [html.unescape(re.sub(r"<[^>]+>", "", c)).strip() for c in CELL.findall(inner)]
            if len(cells) < 5:
                continue
            q = urllib.parse.parse_qs(urllib.parse.urlparse(html.unescape(href)).query)
            rows.append({
                "ztmId": q.get("ztm_vehicle", [None])[0],
                "number": cells[0], "make": cells[1], "model": cells[2],
                "carrier": cells[3], "depot": cells[4],
            })
        last = max([int(n) for n in re.findall(r"baza-danych-pojazdow/page/(\d+)", body)] + [1])
        if not found or page >= last:
            return rows
        page += 1


def year_options(body):
    m = re.search(r'name="ztm_year"(.*?)</select>', body, re.S)
    return [v for v in re.findall(r'<option value="(\d{4})"', m.group(1))] if m else []


def scrape():
    years = year_options(get(BASE))
    vehicles = {}
    for traction, kind in TRACTIONS.items():
        for y in years:
            rows = scrape_list({"ztm_traction": traction, "ztm_year": y})
            if rows:
                print(f"{kind} {y}: {len(rows)}")
            for r in rows:
                vehicles[(kind, r["ztmId"] or r["number"])] = {**r, "kind": kind, "year": int(y)}
        rest = scrape_list({"ztm_traction": traction})
        missing = 0
        for r in rest:
            key = (kind, r["ztmId"] or r["number"])
            if key not in vehicles:
                vehicles[key] = {**r, "kind": kind, "year": None}
                missing += 1
        print(f"{kind}: {len(rest)} total, {missing} without year")
    out = sorted(vehicles.values(), key=lambda v: (v["kind"], v["number"]))
    RAW.parent.mkdir(exist_ok=True)
    RAW.write_text(json.dumps({"fetched": date.today().isoformat(), "source": BASE, "vehicles": out},
                              ensure_ascii=False, indent=0))
    return out


# ---------------------------------------------------------------- build

CARRIERS = {
    "Miejskie Zakłady Autobusowe": "MZA",
    "Tramwaje Warszawskie": "Tramwaje Warszawskie",
    "Komunikacja Miejska Łomianki": "KM Łomianki",
    "PKS Grodzisk Mazowiecki": "PKS Grodzisk",
    "Przewóz Osób Dariusz Średnicki": "Średnicki",
    "Przewozy autokarowe Krzysztof Grygiel": "Grygiel",
    "ReloBus Transport Polska": "ReloBus",
}


# ZTM lists factory type codes; spotters know the marketing names. The code stays
# visible as `code` on the model page.
DISPLAY_NAMES = {
    ("MAN", "A21"): "MAN Lion\u2019s City",
    ("MAN", "A23"): "MAN Lion\u2019s City G",
    ("MAN", "A37"): "MAN Lion\u2019s City",
    ("Mercedes-Benz", "628"): "Mercedes-Benz Conecto G",
    ("Mercedes-Benz", "628B01"): "Mercedes-Benz Conecto",
    ("Mercedes-Benz", "628B02"): "Mercedes-Benz Conecto G",
    ("Solaris", "Urbino 18E"): "Solaris Urbino 18 electric",
    ("Solaris", "Urbino 12E"): "Solaris Urbino 12 electric",
    ("Solaris", "Urbino 18H"): "Solaris Urbino 18 hybrid",
    ("Solaris", "Urbino 18CNG"): "Solaris Urbino 18 CNG",
    ("Solaris", "Urbino 12CNG"): "Solaris Urbino 12 CNG",
    ("Autosan", "M18LF"): "Autosan Sancity 18LF",
    ("Solbus", "SM18"): "Solbus Solcity 18",
    ("Solbus", "SM12"): "Solbus Solcity 12",
    ("Scania", "M323"): "Scania CityWide",
    ("Otokar", "LA16SR2BX"): "Otokar Kent C",
    ("Güleryüz", "GD272"): "Güleryüz Cobra GD272",
    ("Yutong", "U12-B"): "Yutong U12",
    ("Ursus", "CS2"): "Ursus City Smile",
    ("HRC", "140N"): "Hyundai Rotem 140N",
    ("HRC", "141N"): "Hyundai Rotem 141N",
    ("HRC", "142N"): "Hyundai Rotem 142N",
    ("HCP", "123N"): "Cegielski 123N",
    ("Konstal", "105N"): "Konstal 105Na",
    ("Alstom Konstal", "105N"): "Alstom Konstal 105Na",
    ("Gdańska Fabryka Wagonów / WIwK", "K"): "Gdańsk type K",
    ("Credé/Düwag", "4EGTw"): "Credé/Düwag 4EGTw",
}


def display_name(make, model):
    return DISPLAY_NAMES.get((make, model), f"{make} {model}".strip())


def short_carrier(name):
    name = re.sub(r"\s*Sp\. z o\.o\.?$", "", name).strip()
    return CARRIERS.get(name, name)


def parse_depot(s):
    """'R-4 "Stalowa" (R-13)' -> ('R-4', 'Stalowa'); 'Kabaty' -> ('', 'Kabaty')."""
    m = re.match(r'(R-\d+)\s*"([^"]+)"', s)
    return (m.group(1), m.group(2)) if m else ("", s)


def slug(s):
    s = s.lower().translate(str.maketrans("ąćęłńóśźż", "acelnoszz"))
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")


def build(vehicles):
    groups = defaultdict(list)
    for v in vehicles:
        if not v["number"].isdigit():
            continue  # e.g. "403-1": trailer cars of a heritage set
        groups[(v["kind"], v["make"], v["model"])].append(v)

    models = []
    for (kind, make, model), vs in groups.items():
        by_year = defaultdict(list)
        for v in vs:
            by_year[v["year"]].append(v)
        batches = []
        for y, bvs in sorted(by_year.items(), key=lambda kv: (kv[0] is None, -(kv[0] or 0))):
            depot = Counter(parse_depot(v["depot"]) for v in bvs).most_common(1)[0][0]
            batches.append({
                "year": y,
                "depotCode": depot[0], "depotName": depot[1],
                "numbers": sorted(int(v["number"]) for v in bvs),
            })
        years = [v["year"] for v in vs if v["year"]]
        models.append({
            "id": slug(f"{kind}-{make}-{model}"),
            "name": display_name(make, model),
            "make": make,
            "code": f"{make} {model}".strip(),
            "kind": kind,
            "operators": [c for c, _ in Counter(short_carrier(v["carrier"]) for v in vs).most_common()],
            "fleet": len(vs),
            "firstYear": min(years) if years else None,
            "lastYear": max(years) if years else None,
            "batches": batches,
        })
    models.sort(key=lambda m: (m["kind"], -m["fleet"], m["name"]))

    depots = sorted({parse_depot(v["depot"]) + (v["kind"],) for v in vehicles if v["depot"]})
    raw = json.loads(RAW.read_text())
    OUT.write_text(json.dumps({
        "source": f"ZTM Warszawa vehicle database ({BASE}), fetched {raw['fetched']}",
        "fetched": raw["fetched"],
        "models": models,
        "depots": [{"code": c, "name": n, "kind": k} for c, n, k in depots],
    }, ensure_ascii=False, separators=(",", ":")))
    total = sum(m["fleet"] for m in models)
    print(f"wrote {OUT.relative_to(ROOT)}: {len(models)} models, {total} vehicles, {len(depots)} depots")


if __name__ == "__main__":
    data = json.loads(RAW.read_text())["vehicles"] if "--offline" in sys.argv else scrape()
    build(data)
