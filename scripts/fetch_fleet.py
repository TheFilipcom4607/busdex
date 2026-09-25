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
    first = get(BASE)
    years = year_options(first)
    if not years:
        # CloudFront answers some networks (e.g. CI runners) with a 200 challenge page
        # instead of the database; say so rather than building an empty fleet.
        title = re.search(r"<title>(.*?)</title>", first, re.S)
        raise RuntimeError(f"no year filter on the page — not the vehicle database? "
                           f"title={title.group(1).strip() if title else None!r}, {len(first)} bytes: "
                           f"{re.sub(r'\\s+', ' ', first[:400])!r}")
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
    ("MAN", "A21"): "MAN Lion\u2019s City CNG",
    ("MAN", "A23"): "MAN Lion\u2019s City G",
    ("MAN", "A37"): "MAN Lion\u2019s City Hybrid",
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
    ("Otokar", "LA16SR2BX"): "Otokar Vectio C",
    ("Otokar", "Kent C LF Mild Hybrid"): "Otokar Kent C Hybrid",
    ("Güleryüz", "GD272"): "Güleryüz Cobra GD272",
    ("Yutong", "U12-B"): "Yutong U12",
    ("Isuzu", "B120"): "Isuzu Citiport 12",
    # ZTM puts the whole name in the make column.
    ("Procity 12 M", ""): "BMC Procity 12LF",
    # Minibuses Mercus builds on a Mercedes-Benz Sprinter chassis (phototrans.eu).
    ("Mercus", "906BB62"): "Mercus MB Sprinter City",
    # The same Mercus City body on a MAN TGE 6.180 (phototrans.eu).
    ("Mercus", "SYN2Z"): "Mercus MAN TGE City",
    ("Ursus", "CS2"): "Ursus City Smile",
    ("HRC", "140N"): "Hyundai Rotem 140N",
    ("HRC", "141N"): "Hyundai Rotem 141N",
    ("HRC", "142N"): "Hyundai Rotem 142N",
    ("HCP", "123N"): "Cegielski 123N",
    ("Konstal", "105N"): "Konstal 105Na",
    ("Alstom Konstal", "105N"): "Konstal 105N2k",
    ("Alstom Konstal", "116N"): "Alstom 116Na",
    ("Pesa", "120N"): "Pesa 120N / 120Na Swing",
    ("Pesa", "128N"): "Pesa 128N Jazz Duo",
    ("Pesa", "134N"): "Pesa 134N Jazz",
    ("Linke-Hoffmann", "Lw"): "Linke-Hofmann Lw",
    ("Gdańska Fabryka Wagonów / WIwK", "K"): "Gdańsk type K",
    ("Credé/Düwag", "4EGTw"): "Credé/Düwag 4EGTw",
}


# Tourist-line and museum stock: out on summer weekends (tram lines T and 36, bus
# line 100) or only for special events, never on regular routes. The app tags these
# VINTAGE and leaves them out of the "% of fleet" total. Checked 2026-09-22 against
# kmkm.waw.pl/wlt-2026 and live tracking (api.zbiorkom.live).
VINTAGE = {
    "tram-falkenried-a", "tram-linke-hoffmann-lw", "tram-lilpop-c",
    "tram-gdanska-fabryka-wagonow-wiwk-k", "tram-cred-d-wag-4egtw", "tram-konstal-n",
    "tram-konstal-4n", "tram-konstal-13n", "tram-konstal-102n",
    "bus-ikarus-260", "bus-ikarus-280", "bus-solaris-urbino-15",
}

# Vintage vehicles filed under a regular model in the ZTM database: split out into a
# vintage model of their own. KMKM-owned 105Na sets (kmkm.waw.pl/tramwaje-lista).
VINTAGE_NUMBERS = {
    ("TRAM", "Konstal", "105N"): {1000, 1001, 1251, 1252},
    # MZA's own heritage buses sit in the 69xx range (with the Ikarus and Urbino 15).
    ("BUS", "MAN", "A23"): {6922},
    ("BUS", "Solaris", "Urbino 18"): {6923},
}

# Preserved buses that aren't in the ZTM database at all: the KMKM club's collection
# (kmkm.waw.pl/autobusy-lista, 2026-09-22) plus MZA heritage buses on tourist line 100
# in 2026 (kmkm.waw.pl/wlt-2026). (make, model, number, owner, build year from the
# club's page for each bus; None where it gives none). Makes/models match the ZTM
# spelling where a model already exists, so they join it.
EXTRA_VINTAGE_BUSES = [
    ("Chausson", "AH 48", 395, "KMKM", 1950),
    ("Jelcz", "272 MEX", 1816, "KMKM", 1972),
    ("Jelcz", "272 MEX", 1983, "KMKM", 1977),
    ("Berliet", "PR100", 3873, "KMKM", 1980),
    ("Ikarus", "260", 289, "KMKM", 1982),
    ("Ikarus", "260", 6306, "KMKM", 1993),
    ("Ikarus", "280", 646, "KMKM", None),
    ("Ikarus", "280", 691, "KMKM", None),
    ("Ikarus", "280", 2600, "KMKM", 1987),
    ("Ikarus", "280", 5715, "KMKM", 1997),
    ("Ikarus", "280", 5741, "MZA", None),
    ("Ikarus", "405", 6454, "KMKM", 1994),
    ("Ikarus", "411", 6550, "KMKM", 1995),
    ("Ikarus Zemun", "IK-160P", 70504, "KMKM", 1987),
    ("Jelcz", "043", 8058, "KMKM", 1974),
    ("Jelcz", "043", 8081, "KMKM", 1986),
    ("Jelcz", "PO1", 618, "KMKM", None),
    ("Jelcz", "PAT-4", 643, "KMKM", None),
    ("Jelcz", "M11", 95, "KMKM", 1987),
    ("Jelcz", "L11", 90904, "KMKM", 1989),
    ("Jelcz", "PR110M", 4617, "KMKM", 1991),
    ("Jelcz", "PR110U", 5299, "KMKM", 1978),
    ("Jelcz", "120MM/1", 4340, "KMKM", 1993),
    ("Jelcz", "M121M", 4891, "KMKM", 1998),
    ("Jelcz", "M121I/4", 4942, "MZA", None),
    ("San", "H-100A", 8082, "KMKM", 1972),
    ("San", "H-100B", 160, "KMKM", 1973),
    ("Solaris", "Urbino 15", 8731, "KMKM", 2001),
]


# ZTM files some vehicles of one type under a different make/model string; live tracking
# shows they're the same type, so they join it: (kind, make, model) -> (make, model).
MERGE = {
    ("TRAM", "Alstom Konstal", ""): ("Alstom Konstal", "105N"),  # #2011, #2013: 105N2k
    ("TRAM", "Konstal", "116N"): ("Alstom Konstal", "116N"),     # #3002-3004: 116Na
    ("BUS", "Iveco", "CBLE4/00"): ("Iveco", "Crossway LE"),       # #39533: CBLE is the Crossway LE's factory code
}


# Where the ZTM database lags behind the street (per Warszawikia, 2 Sep 2026):
# Mobilis's new Otokars run since 1 Sep 2026 but aren't listed yet, and its MAN Lion's
# City Hybrids (#9501-9561) were retired in 2026 but are still listed.
EXTRA_BUSES = [
    ("Otokar", "Kent C LF Mild Hybrid", n, "Mobilis", 2026) for n in range(9601, 9655)
]
# Buses on loan for a trial, not (yet) in the ZTM database. The app tags them ON TEST:
# catchable and in the book, but, like vintage stock, outside the fleet % and the set
# badges, since they're gone again after a few weeks. (make, model, number, operator,
# depot, where it runs, when: shown where a build year would be, since a demo bus's
# year isn't what matters.) Irizar ie tram 12 #959: MZA's trial from R-4 Stalowa, mid
# to end of September 2026 (TransInfo, Polskie Radio 24), seen live on line 106 on
# 2026-09-25 (api.um.warszawa.pl).
TEST_BUSES = [
    ("Irizar", "ie tram 12", 959, "MZA", 'R-4 "Stalowa" (R-13)',
     "LINE 106 · ALSO 122, 123, 157, 166 · TRIAL UNTIL 30 SEP 2026", "ON TRIAL SEP 2026"),
]
TRIALS = {(make, model): (runs, when) for make, model, _, _, _, runs, when in TEST_BUSES}

RETIRED = {
    ("BUS", "MAN", "A37", "Mobilis"): set(range(9501, 9562)),
}


def with_vintage_extras(vehicles):
    """ZTM rows plus the preserved buses it doesn't list; marks split-out vintage rows."""
    out = []
    for v in vehicles:
        carrier = short_carrier(v["carrier"])
        if v["number"].isdigit() and int(v["number"]) in RETIRED.get((v["kind"], v["make"], v["model"], carrier), set()):
            continue
        make, model = MERGE.get((v["kind"], v["make"], v["model"]), (v["make"], v["model"]))
        v = {**v, "make": make, "model": model}
        split = VINTAGE_NUMBERS.get((v["kind"], v["make"], v["model"]), set())
        out.append({**v, "vintage": v["number"].isdigit() and int(v["number"]) in split})
    # Once ZTM catches up and lists one of these itself, its own row wins.
    listed = {(v["kind"], v["number"]) for v in vehicles}
    for make, model, number, owner, year in EXTRA_BUSES:
        if ("BUS", str(number)) in listed:
            continue
        out.append({"ztmId": "", "number": str(number), "make": make, "model": model,
                    "carrier": owner, "depot": "Ursus", "kind": "BUS", "year": year, "vintage": False})
    for make, model, number, owner, depot, _, _ in TEST_BUSES:
        if ("BUS", str(number)) in listed:
            continue
        out.append({"ztmId": "", "number": str(number), "make": make, "model": model,
                    "carrier": owner, "depot": depot, "kind": "BUS", "year": None,
                    "vintage": False, "onTest": True})
    for make, model, number, owner, year in EXTRA_VINTAGE_BUSES:
        out.append({"ztmId": "", "number": str(number), "make": make, "model": model,
                    "carrier": owner, "depot": "", "kind": "BUS", "year": year, "vintage": True})
    return out


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
    for v in with_vintage_extras(vehicles):
        if not v["number"].isdigit():
            continue  # e.g. "403-1": trailer cars of a heritage set
        split = v["vintage"] and (v["kind"], v["make"], v["model"]) in VINTAGE_NUMBERS
        groups[(v["kind"], v["make"], v["model"], split)].append(v)

    models = []
    for (kind, make, model, split), vs in groups.items():
        if len({v["number"] for v in vs}) != len(vs):
            raise ValueError(f"duplicate fleet number in {make} {model}")
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
        model_id = slug(f"{kind}-{make}-{model}") + ("-vintage" if split else "")
        models.append({
            "id": model_id,
            "name": display_name(make, model),
            "make": make,
            "code": f"{make} {model}".strip(),
            "kind": kind,
            "operators": [c for c, _ in Counter(short_carrier(v["carrier"]) for v in vs).most_common()],
            "fleet": len(vs),
            "firstYear": min(years) if years else None,
            "lastYear": max(years) if years else None,
            "batches": batches,
            # Curated models, split-out sets, and models that exist only as preserved buses.
            "vintage": model_id in VINTAGE or split or all(v["vintage"] for v in vs),
            "onTest": all(v.get("onTest", False) for v in vs),
            **({"runs": TRIALS[(make, model)][0], "trial": TRIALS[(make, model)][1]}
               if (make, model) in TRIALS else {}),
        })
    models.sort(key=lambda m: (m["kind"], -m["fleet"], m["name"]))
    missing = VINTAGE - {m["id"] for m in models}
    assert not missing, f"VINTAGE ids not in the data any more: {missing}"

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
