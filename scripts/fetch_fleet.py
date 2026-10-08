#!/usr/bin/env python3
"""Build Tabor/Resources/fleet.json: Warsaw's buses and trams, by model and batch.

Two sources, plus the hand-kept lists below:
- The last scrape of ZTM's vehicle database (https://www.ztm.waw.pl/baza-danych-pojazdow/),
  data/ztm-vehicles.json. It's the base, and kept as it is: where the sources disagree, ours
  wins, so model ids never change.
- The city's open-data vehicle list (dane.um.warszawa.pl, get_ztm_pojazdy), refreshed daily,
  data/ztm-pojazdy.json. It adds the vehicles the scrape hasn't got, each joining the model
  most of its type (idMarki) belongs to, plus each model's specs. It also says which vehicles
  still run (a scrape row it has dropped is left out) and where they're based.

Usage:  python3 scripts/fetch_fleet.py            # fetch the city's list + build
        python3 scripts/fetch_fleet.py --offline  # rebuild from the saved files
        python3 scripts/fetch_fleet.py --scrape   # re-scrape ZTM's database too (slow)
        python3 scripts/fetch_fleet.py --allow-drop  # let model ids disappear (on purpose)
        python3 scripts/fetch_fleet.py --touch    # restamp `fetched` even if nothing changed

The city's list needs TABOR_DANE_TOKEN, from the environment or Config/Secrets.xcconfig.
"""
import html
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from datetime import date, datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "ztm-vehicles.json"
CITY = ROOT / "data" / "ztm-pojazdy.json"
OUT = ROOT / "Tabor" / "Resources" / "fleet.json"
DANE = "https://dane.um.warszawa.pl/api/action/get_ztm_pojazdy"
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


# ---------------------------------------------------------------- the city's list

def dane_token():
    token = os.environ.get("TABOR_DANE_TOKEN")
    if not token:
        secrets = ROOT / "Config" / "Secrets.xcconfig"
        m = re.search(r"^TABOR_DANE_TOKEN\s*=\s*(\S+)", secrets.read_text(), re.M) if secrets.exists() else None
        token = m and m.group(1)
    if not token:
        raise RuntimeError("no TABOR_DANE_TOKEN (environment or Config/Secrets.xcconfig)")
    return token


def fetch_city():
    """The city's vehicle list, trimmed to what the build uses, saved to data/ztm-pojazdy.json."""
    # The city times out on GitHub's runners, so the Action goes through the tabor-live Worker
    # (DANE_URL, with the upload token), as build_routes.py does for the GTFS.
    if os.environ.get("DANE_URL"):
        req = urllib.request.Request(os.environ["DANE_URL"], headers={
            **HEADERS, "Accept": "application/json",
            "Authorization": f"Bearer {os.environ['ROUTES_UPLOAD_TOKEN']}"})
    else:
        req = urllib.request.Request(DANE, data=b"{}", method="POST", headers={
            **HEADERS, "Accept": "application/json", "Content-Type": "application/json",
            "Authorization": dane_token()})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                d = json.loads(r.read())
            break
        except Exception as e:  # noqa: BLE001 — the city drops calls under load
            if attempt == 3:
                raise
            print(f"  ! {e} — retry in {2 ** attempt}s", file=sys.stderr)
            time.sleep(2 ** attempt)
    vehicles = [{
        "kind": kind, "number": v["numerTaborowy"], "idMarki": v["idMarki"], "year": v["rokProdukcji"],
        "carrier": v["nazwaOperatora"] or "", "depot": v["nazwaZajezdni"] or "",
        "colour": v["kolorPojazdu"],
    } for key, kind in (("busy", "BUS"), ("tramwaje", "TRAM")) for v in d[key]]
    keep = ("idMarki", "marka", "typ", "dlugosc", "rodzajZasilania", "zasilanie",
            "liczMiejscSiedzacychTab", "liczMiejscTab", "klimatyzacja", "podloga")
    types = {kind: [{k: t.get(k) for k in keep} for t in d[key]]
             for key, kind in (("markiBus", "BUS"), ("markiTramwaje", "TRAM"))}
    if len(vehicles) < 2000:
        raise RuntimeError(f"only {len(vehicles)} vehicles in the city's list: not a usable answer")
    city = {"fetched": date.today().isoformat(), "source": DANE,
            "vehicles": sorted(vehicles, key=lambda v: (v["kind"], v["number"])), "types": types}
    CITY.write_text(json.dumps(city, ensure_ascii=False, indent=0))
    print(f"city: {len(vehicles)} vehicles, {sum(len(t) for t in types.values())} types")
    return city


def with_city(vehicles, city, report=True):
    """The scrape plus the vehicles only the city lists. A new number joins the model most
    numbers of its type (idMarki) already belong to; a type nothing known belongs to is
    printed for a human to place, and left out. A scrape row the city no longer lists is
    gone from the fleet (printed), unless STILL_RUNNING keeps it. The city's depot wins: it's
    refreshed daily, the scrape isn't."""
    listed = {(c["kind"], c["number"]): c for c in city["vehicles"]}
    votes = defaultdict(Counter)
    # Hand-added deliveries count as known too: they're how a brand-new type gets placed.
    known = [(v["kind"], v["number"], v["make"], v["model"]) for v in vehicles]
    known += [("BUS", str(n), make, model) for make, model, n, *_ in EXTRA_BUSES]
    for kind, number, make, model in known:
        if c := listed.get((kind, number)):
            votes[(kind, c["idMarki"])][(make, model)] += 1
    ours = {(v["kind"], v["number"]) for v in vehicles}
    out, added, unplaced, gone = [], Counter(), defaultdict(list), defaultdict(list)
    for v in vehicles:
        c = listed.get((v["kind"], v["number"]))
        if c:
            out.append({**v, "depot": c["depot"] or v["depot"]})
        elif (v["kind"], v["number"]) in STILL_RUNNING or not v["number"].isdigit():
            out.append(v)
        else:
            retired = RETIRED.get((v["kind"], v["make"], v["model"], short_carrier(v["carrier"])), set())
            if int(v["number"]) not in retired:
                gone[(v["kind"], v["make"], v["model"])].append(int(v["number"]))
    for (kind, number), c in sorted(listed.items()):
        if (kind, number) in ours or not number.isdigit():
            continue
        if not votes[(kind, c["idMarki"])]:
            unplaced[(kind, c["idMarki"])].append(number)
            continue
        make, model = votes[(kind, c["idMarki"])].most_common(1)[0][0]
        out.append({"ztmId": "", "number": number, "make": make, "model": model, "carrier": c["carrier"],
                    "depot": c["depot"], "kind": kind, "year": c["year"]})
        added[f"{make} {model}"] += 1
    if not report:
        return out
    for model, n in added.most_common():
        print(f"  + {n} from the city's list: {model}")
    for (kind, id_marki), numbers in sorted(unplaced.items()):
        print(f"  ? {kind} type {id_marki} fits no model yet, left out: {', '.join(numbers)}")
    for (kind, make, model), numbers in sorted(gone.items()):
        print(f"  - gone from the city's list, left out: {kind} {make} {model} {span(numbers)}")
    return out


def span(numbers):
    """[1, 2, 3, 7] -> '1-3, 7'"""
    numbers, runs = sorted(numbers), []
    for n in numbers:
        if runs and n == runs[-1][1] + 1:
            runs[-1][1] = n
        else:
            runs.append([n, n])
    return ", ".join(f"{a}-{b}" if a != b else f"{a}" for a, b in runs)


# Both of ZTM's lists number a few heritage cars with a suffix. "403-1" is K #403 itself, the
# "Berlinek" (Warszawikia, kmkm.waw.pl; issue #33), not a trailer, and its fleet number is 403.
# MZA's Urbino 12 #1400 became heritage bus #6900 in October 2026 (phototrans.eu): the scrape
# still has the old number. Drop this once a scrape lists #6900 itself.
RENUMBER = {("TRAM", "403-1"): "403", ("BUS", "1400"): "6900"}


def renumbered(rows):
    return [{**r, "number": RENUMBER.get((r["kind"], r["number"]), r["number"])} for r in rows]


def load_raw():
    return renumbered(json.loads(RAW.read_text())["vehicles"])


def load_city():
    city = json.loads(CITY.read_text())
    return {**city, "vehicles": renumbered(city["vehicles"])}


def source_rows():
    """Every vehicle row fleet.json is built from, before the hand-kept lists."""
    return with_city(load_raw(), load_city(), report=False) if CITY.exists() else load_raw()


# What the city calls each drive, for the model page.
DRIVES = {
    ("Spalinowy", "ON"): "diesel", ("Spalinowy", "CNG"): "cng", ("Spalinowy", "LNG"): "lng",
    ("EV", "EV"): "electric", ("EV", "H2"): "hydrogen",
}
# Vehicles in anything but ZTM's red and yellow, checked against photos: the city's list
# can't be trusted with this. Its scheme field says who specified the paint, not how it looks
# (#8802, "producencki", is plain red and yellow), and its colour field misses repaints (#5869
# is still "srebrny", silver, but has been red and yellow since at least May 2025).
# (kind, number) -> a `Livery` in the app. Photos from phototrans.eu.
LIVERIES = {
    ("BUS", 8396): "greyRed",  # Urbino 18 hybrid: grey with a red skirt, Wawelska, March 2026
    ("BUS", 8397): "greyRed",  # the same, 2023 (no newer photo)
    ("BUS", 8399): "greyRed",  # the same, 16 July 2026
}
# The one colour the city's list gets right: suburban (L) buses are blue, whole models of
# them (confirmed on the street, 2026-09-28).
SUBURBAN_BLUE = "RAL 5010 (L)"


def specs(t, kind):
    """A model's specs from the city's row for its type. Trams are all electric: no drive."""
    drive = "hybrid" if t.get("rodzajZasilania") == "Hybryda" else DRIVES.get((t.get("rodzajZasilania"), t.get("zasilanie")))
    s = {
        "length": t.get("dlugosc"), "drive": drive if kind == "BUS" else None,
        "seats": t.get("liczMiejscSiedzacychTab"), "places": t.get("liczMiejscTab"),
        "airCon": t.get("klimatyzacja"), "floor": t.get("podloga") if t.get("podloga") in ("LF", "LE", "HF") else None,
    }
    return {k: v for k, v in s.items() if v is not None} or None


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
    # Split by SPLIT below; names per Warszawikia.
    ("Pesa", "120N"): "Pesa 120N Tramicus",
    ("Pesa", "120Na"): "Pesa 120Na Swing",
    ("Pesa", "120NaDuo"): "Pesa 120NaDuo Swing Duo",
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
    "tram-falkenried-a", "tram-linke-hoffmann-lw", "tram-lilpop-c", "tram-warsztaty-glowne-w",
    "tram-gdanska-fabryka-wagonow-wiwk-k", "tram-konstal-n",
    "tram-konstal-4n", "tram-konstal-13n", "tram-konstal-102n",
    "bus-ikarus-260", "bus-ikarus-280", "bus-solaris-urbino-15",
}

# Vintage vehicles filed under a regular model in the ZTM database: split out into a
# vintage model of their own. KMKM-owned 105Na sets (kmkm.waw.pl/tramwaje-lista), and #1006,
# TW's wood-panelled promotional car: a works car since 2012, out for hire and line T, never
# on regular routes (tramwar.pl/tw1006.html; the city's list gives it a type of its own).
VINTAGE_NUMBERS = {
    ("TRAM", "Konstal", "105N"): {1000, 1001, 1006, 1251, 1252},
    # MZA's own heritage buses sit in the 69xx range (with the Ikarus and Urbino 15). #6900 is
    # the 2007 Urbino 12 #1400, renumbered after its last run on 18.09.2026 (phototrans.eu).
    ("BUS", "MAN", "A23"): {6922},
    ("BUS", "Solaris", "Urbino 18"): {6923},
    ("BUS", "Solaris", "Urbino 12"): {6900},
}

# Trams that run as two coupled cars, each with its own fleet number. The live feed reports a
# set once, under one car's number (usually the even one), so the other car is never in it.
# Konstal 105Na: Warszawikia writes its sets as pairs (1000+1001, 1252+1251). 105N2k/2000: sets
# like 2084+2085, and 31 of its cars are cab-less trailers that never run alone. Cegielski 123N:
# "all 30 cars coupled in 15 sets" (Warszawikia). In the live feed (checked for issue #23), 46 of
# 47 running 105Na numbers were even, 44 of 44 105N2k and 10 of 10 123N; single-car models split
# about half and half.
# The vintage N/4N trailers are TRAILERS below, not sets. The vintage 105Nas aren't COUPLED:
# their FIXED_SETS pair the KMKM's cars, and #1006 runs alone (its partner #1007 was scrapped
# in 2011).
COUPLED = {
    "tram-konstal-105n", "tram-alstom-konstal-105n", "tram-hcp-123n",
}

# Sets that always run together: the KMKM's 105Na sets (kmkm.waw.pl/tramwaje-lista) and the
# 13N "żaba" pair on tourist line 36 (kmkm.waw.pl/wlt-2026). A set in a model that isn't in
# COUPLED marks only its own two cars as coupled.
FIXED_SETS = [(1000, 1001), (1252, 1251), (821, 818)]

# Vintage trailers with no motor of their own: ND #1620 and 4ND #1811 (kmkm.waw.pl/tramwaje-lista;
# ZTM files both under "Konstal N"). They're hitched behind whichever motor car runs that day:
# Warszawikia has K #403 + 4ND, 4Nj + 4ND and 4Nj + ND on line W, so there are no fixed pairs.
# TOWING are the models whose cars pull them (issue #33). Emitted as "trailers" on the model that
# holds them and "tows" on the towing models; older app versions ignore both keys.
TRAILERS = {1620, 1811}
TOWING = {"tram-konstal-n", "tram-konstal-4n", "tram-gdanska-fabryka-wagonow-wiwk-k"}

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
    # MZA's own heritage buses on line 100 (issue #36; build years from wawakom.pl). The 1932
    # Somua is left out: it has no fleet number, so it can't be caught.
    ("Jelcz", "M181M", 6971, "MZA", 1999),
    ("Neoplan", "N4020td", 6960, "MZA", 1999),
]


# Tramwaje Warszawskie's works cars: measurement, transport, welding and universal cars,
# mostly rebuilt from withdrawn K and 13N trams. Neither of ZTM's lists has them as such (#1315
# and #2400 are still listed as passenger cars, RETIRED below; #2112 and #2113 are also 105N2k
# numbers), so they're all added by hand from tramwar.pl/twgosp.html (checked 2026-10-08). The
# app tags them WORKS: catchable and in the book, but outside the fleet % and the rarity tiers.
# Left out: the two shunters (#1, #2), which never leave the T-1 yard; the tamper P1, grinder S1
# and S-9/S-11, whose numbers aren't numbers; and the motorless trailers. #407 stays VINTAGE and
# #1006 in the vintage 105Na, as both run for the public. "402" and "2412" are the second cars
# to carry those numbers (402" on the page).
# (make, model, number, build year, depot: R- depots as the city writes them, T-1 the traction
# power and track unit, T-3 the tram repair works, CLET TW's electrical lab.)
WORKS_TRAMS = [
    ("Konstal", "13N", 12, 1962, 'R-2 "Praga"'),
    ("Konstal", "13N", 53, 1964, 'R-4 "Żoliborz"'),
    ("Konstal", "13N", 388, 1967, 'T-1 "ZETiT"'),  # overhead-line measurement car
    ("Konstal", "13N", 402, 1968, 'R-1 "Wola"'),
    ("Konstal", "13N", 2412, 1969, 'R-3 "Mokotów"'),
    ("Konstal", "105N", 1022, 1975, "CLET"),  # 105N/LAB, the rolling laboratory (tramwar.pl/tw-laboratorium.html)
    ("Konstal", "105N", 1315, 1990, 'R-5 "Annopol"'),
    ("Gdańska Fabryka Wagonów / WIwK", "K", 2002, 1940, 'R-1 "Wola"'),
    ("Gdańska Fabryka Wagonów / WIwK", "K", 2112, 1940, 'T-1 "ZETiT"'),
    ("Gdańska Fabryka Wagonów / WIwK", "K", 2113, 1940, 'T-1 "ZETiT"'),
    ("Gdańska Fabryka Wagonów / WIwK", "K", 2400, 1940, 'R-4 "Żoliborz"'),
    ("Gdańska Fabryka Wagonów / WIwK", "K", 2406, 1940, 'T-3 "ZNT"'),
    ("Gdańska Fabryka Wagonów / WIwK", "K", 2407, 1940, 'T-3 "ZNT"'),
    # Built new as universal works cars (and snowploughs) by ZPS Stargard in 2015
    # (tramwar.pl/tw-uniwersalne.html).
    *[("ZPS Stargard", "4NA-DT", n, 2015, 'T-1 "ZETiT"') for n in range(9001, 9007)],
]


# ZTM files some vehicles of one type under a different make/model string; live tracking
# shows they're the same type, so they join it: (kind, make, model) -> (make, model).
MERGE = {
    ("TRAM", "Alstom Konstal", ""): ("Alstom Konstal", "105N"),  # #2011, #2013: 105N2k
    ("TRAM", "Konstal", "116N"): ("Alstom Konstal", "116N"),     # #3002-3004: 116Na
    ("BUS", "Iveco", "CBLE4/00"): ("Iveco", "Crossway LE"),       # #39533: CBLE is the Crossway LE's factory code
}

# Single vehicles ZTM files under another type: (kind, number) -> (make, model). The 105Ni
# sets 1364+1363, 1390+1386, 2006+2007 and 2008+2009 have the same rebuild as the 105Ni cars
# filed as Alstom Konstal (1391, 2010-2023), but ZTM calls them plain Konstal (tramwar.pl
# twstat.html, tram105n2k.html). Their catches move with them (`formerly`).
RETYPE = {("TRAM", str(n)): ("Alstom Konstal", "105N") for n in (1363, 1364, 1386, 1390, 2006, 2007, 2008, 2009)}


# ZTM files some different types under one make/model string; these split them by number:
# (kind, make, model) -> [(numbers, model, id)], plus a make when the part has another maker.
# Each part names its id, since one of them keeps the id the whole family had (the biggest,
# so most catches stay put) and the others can't take the slug that's left. The app moves
# catches to the part that has their number (`formerly` in fleet.json).
SPLIT = {
    # The 15 original 120Ns, the 180 Swings and the 6 two-way Swing Duos (Warszawikia; the
    # city's list has them as types of their own: 31.82 m, 30.12 m, and 30.12 m with 28 seats).
    ("TRAM", "Pesa", "120N"): [
        (range(3101, 3116), "120N", "tram-pesa-120n-tramicus"),
        (range(3116, 3296), "120Na", "tram-pesa-120n"),
        (range(3501, 3507), "120NaDuo", "tram-pesa-120naduo"),
    ],
    # #2204 is a W tower car built by the Warsztaty Główne in 1928, not a Lilpop C (issue #33;
    # kmkm.waw.pl/w-2204-2, transphoto.org). A museum car since 1996, at R-3 Mokotów since 2018.
    ("TRAM", "Lilpop", "C"): [
        ({257}, "C", "tram-lilpop-c"),
        ({2204}, "W", "tram-warsztaty-glowne-w", "Warsztaty Główne"),
    ],
}


# Where the ZTM database lags behind the street (per Warszawikia, 2 Sep 2026):
# Mobilis's new Otokars run since 1 Sep 2026 but aren't listed yet, and its MAN Lion's
# City Hybrids (#9501-9561) were retired in 2026 but are still listed. MZA's second
# batch of 30 Yutong U12s (#1940-1969, R-1 Woronicza) runs since 3 Sep 2026 (per
# Warszawikia, 25 Sep 2026; 13 of them seen live that day). New Solaris Urbino 18
# electrics are coming in at R-2 Kleszczowa as #58xx (MZA ordered 50 for 2H 2026);
# only the numbers seen live (2026-09-25, and 10 more on 2026-09-27) are listed, not
# the whole assumed range.
# Since 2026-09-28 the city's list has most of these, and its rows win, so the entries retire
# themselves. Keep them anyway: they're how the city's rows of a type ZTM's scrape lacks
# (the Otokar Kent C) find their model.
# (make, model, number, operator, year, depot.)
EXTRA_BUSES = [
    *[("Otokar", "Kent C LF Mild Hybrid", n, "Mobilis", 2026, "Ursus") for n in range(9601, 9655)],
    *[("Yutong", "U12-B", n, "MZA", 2026, 'R-1 "Woronicza" (R-07)') for n in range(1940, 1970)],
    *[("Solaris", "Urbino 18E", n, "MZA", 2026, 'R-2 "Kleszczowa" (R-11)')
      for n in (5803, 5804, 5805, 5806, 5807, 5808, 5811, 5814, 5815, 5816, 5817, 5819, 5821,
                5822, 5823, 5827, 5828, 5829, 5830, 5831, 5833, 5835)],
]
# Buses on loan for a trial, not (yet) in the ZTM database. The app tags them ON TEST:
# catchable and in the book, but, like vintage stock, outside the fleet % and the set
# badges, since they're gone again after a few weeks. (make, model, number, operator,
# depot, where it runs, when: shown where a build year would be, since a demo bus's
# year isn't what matters. Then the same two in Polish, for the app's Polish UI.)
# Never remove a row once its trial ends: people who caught the bus keep it in their
# book, and the book only shows models fleet.json still has.
# Irizar ie tram 12 #959: MZA's trial from R-4 Stalowa, mid to end of September 2026 (TransInfo, Polskie Radio 24), seen live on line 106 on
# 2026-09-25 (api.um.warszawa.pl). MZA's press office (email, 2026-10-02): extended to 23 October, mainly
# on 106 until 7 October (122 on 3 Oct, 166 on 4 Oct).
TEST_BUSES = [
    ("Irizar", "ie tram 12", 959, "MZA", 'R-4 "Stalowa" (R-13)',
     "LINE 106 · ALSO 122, 123, 157, 166 · TRIAL UNTIL 23 OCT 2026", "ON TRIAL SEP–OCT 2026",
     "LINIA 106 · TAKŻE 122, 123, 157, 166 · TESTY DO 23 PAŹ 2026", "TESTY WRZ–PAŹ 2026"),
]
TRIALS = {(make, model): t for make, model, _, _, _, *t in TEST_BUSES}

RETIRED = {
    ("BUS", "MAN", "A37", "Mobilis"): set(range(9501, 9562)),
    # Old trams ZTM still lists that neither KMKM's heritage list nor Warszawikia has: works cars,
    # or (#504) sold to a private buyer (issue #33, 2026-10-03).
    # #2400 too: KMKM keeps it, but with no seats, and tramwar.pl/twgosp.html lists it as a
    # transport works car rebuilt from #408 in 1969 (issue #33, 2026-10-05). It's in WORKS_TRAMS.
    ("TRAM", "Gdańska Fabryka Wagonów / WIwK", "K", "Tramwaje Warszawskie"): {2400, 2405},
    ("TRAM", "Konstal", "N", "Tramwaje Warszawskie"): {775, 1724, 1727, 1770},
    ("TRAM", "Konstal", "13N", "Tramwaje Warszawskie"): {504, 534, 535},
    # Struck off on 12.09.2025, a week after its partner #1316, and a works car at R-5 since
    # (tramwar.pl zmtab25.html, twgosp.html). The city still lists it (issue #33, 2026-10-05). It's in
    # WORKS_TRAMS.
    ("TRAM", "Konstal", "105N", "Tramwaje Warszawskie"): {1315},
    # Heritage cars waiting for repair, so not on the street (issue #33, 2026-10-04). Put them
    # back once they run again, and "tram-cred-d-wag-4egtw" back in VINTAGE.
    ("TRAM", "Credé/Düwag", "4EGTw", "Tramwaje Warszawskie"): {205},
    ("TRAM", "Konstal", "102N", "Tramwaje Warszawskie"): {42},
}

# Scrape rows the city's list has dropped that still exist. Anything else the city drops is
# gone: the 2008 Urbino 12s and 18s (#18xx, #88xx) left MZA in 2026, many sold on to other
# towns (phototrans.eu, checked 2026-10-05). (kind, number).
STILL_RUNNING = {
    # The 13N KMKM keeps for special runs, formally TW's works car (kmkm.waw.pl/tramwaje-lista,
    # tramwar.pl/twgosp.html).
    ("TRAM", "407"),
    # Runs as 1390+1386 (tramwar.pl/tram105n2k.html, 2026-09-16); the city dropped only 1390.
    ("TRAM", "1390"),
    # Still with their owners and no withdrawal on phototrans.eu (2026-10-05): off the road for
    # now, not gone. Recheck if they stay off the city's list.
    ("BUS", "6212"), ("BUS", "7308"), ("BUS", "7322"), ("BUS", "7717"),
    ("BUS", "9802"), ("BUS", "9823"), ("BUS", "9854"),
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
        if retype := RETYPE.get((v["kind"], v["number"])):
            v = {**v, "make": retype[0], "model": retype[1], "formerly": slug(f"{v['kind']}-{make}-{model}")}
            make, model = retype
        for numbers, part, part_id, *part_make in SPLIT.get((v["kind"], make, model), []):
            if v["number"].isdigit() and int(v["number"]) in numbers:
                v = {**v, "make": part_make[0] if part_make else make, "model": part, "id": part_id,
                     "formerly": slug(f"{v['kind']}-{make}-{model}")}
        split = VINTAGE_NUMBERS.get((v["kind"], v["make"], v["model"]), set())
        out.append({**v, "vintage": v["number"].isdigit() and int(v["number"]) in split})
    # Once ZTM catches up and lists one of these itself, its own row wins.
    listed = {(v["kind"], v["number"]) for v in vehicles}
    for make, model, number, owner, year, depot in EXTRA_BUSES:
        if ("BUS", str(number)) in listed:
            continue
        out.append({"ztmId": "", "number": str(number), "make": make, "model": model,
                    "carrier": owner, "depot": depot, "kind": "BUS", "year": year, "vintage": False})
    for make, model, number, owner, depot, *_ in TEST_BUSES:
        if ("BUS", str(number)) in listed:
            continue
        out.append({"ztmId": "", "number": str(number), "make": make, "model": model,
                    "carrier": owner, "depot": depot, "kind": "BUS", "year": None,
                    "vintage": False, "onTest": True})
    # Neither of ZTM's lists has these, so a city row with one of their numbers is another
    # vehicle (#1983 is also MZA's 2024 Yutong U12): "unlisted" keeps its specs off them.
    for make, model, number, owner, year in EXTRA_VINTAGE_BUSES:
        out.append({"ztmId": "", "number": str(number), "make": make, "model": model,
                    "carrier": owner, "depot": "", "kind": "BUS", "year": year, "vintage": True,
                    "unlisted": True})
    for make, model, number, year, depot in WORKS_TRAMS:
        out.append({"ztmId": "", "number": str(number), "make": make, "model": model,
                    "carrier": "Tramwaje Warszawskie", "depot": depot, "kind": "TRAM", "year": year,
                    "vintage": False, "works": True, "unlisted": True})
    return out


def display_name(make, model):
    return DISPLAY_NAMES.get((make, model), f"{make} {model}".strip())


def short_carrier(name):
    name = re.sub(r"\s*Sp\. z o\.o\.?$", "", name).strip()
    return CARRIERS.get(name, name)


def parse_depot(s):
    """'R-4 "Stalowa" (R-13)' -> ('R-4', 'Stalowa'); 'Kabaty' -> ('', 'Kabaty'). TW's works units
    are T-: 'T-1 "ZETiT"' -> ('T-1', 'ZETiT')."""
    m = re.match(r'([RT]-\d+)\s*"([^"]+)"', s)
    return (m.group(1), m.group(2)) if m else ("", s)


def slug(s):
    s = s.lower().translate(str.maketrans("ąćęłńóśźż", "acelnoszz"))
    return re.sub(r"[^a-z0-9]+", "-", s).strip("-")


def build(vehicles, city=None):
    city_rows = {(c["kind"], c["number"]): c for c in city["vehicles"]} if city else {}
    types = {(kind, t["idMarki"]): t for kind, ts in city["types"].items() for t in ts} if city else {}
    groups = defaultdict(list)
    for v in with_vintage_extras(vehicles):
        if not v["number"].isdigit():
            continue  # a suffixed number RENUMBER doesn't know yet
        split = v["vintage"] and (v["kind"], v["make"], v["model"]) in VINTAGE_NUMBERS
        groups[(v["kind"], v["make"], v["model"], split, v.get("works", False))].append(v)

    models = []
    for (kind, make, model, split, works), vs in groups.items():
        if len({v["number"] for v in vs}) != len(vs):
            raise ValueError(f"duplicate fleet number in {make} {model}")
        # A batch is one operator's vehicles of one year: KMKM's 1993 Ikarus 260 isn't part of
        # MZA's (#36), and the "Every operator" badge credits the operator of the vehicle caught.
        # And one depot's: a year's delivery is often split across depots (the 128Ns of 2014
        # run from R-1, R-3 and R-5), and the depot badges go by the batch.
        by_year = defaultdict(list)
        for v in vs:
            by_year[(v["year"], short_carrier(v["carrier"]), parse_depot(v["depot"]))].append(v)
        batches = []
        for (y, carrier, depot), bvs in sorted(by_year.items(), key=lambda kv: (kv[0][0] is None, -(kv[0][0] or 0), -len(kv[1]))):
            batches.append({
                "year": y,
                "depotCode": depot[0], "depotName": depot[1],
                "operator": carrier,
                "numbers": sorted(int(v["number"]) for v in bvs),
            })
        years = [v["year"] for v in vs if v["year"]]
        model_id = vs[0].get("id") or slug(f"{kind}-{make}-{model}") + ("-vintage" if split else "-works" if works else "")
        if len({v.get("id") for v in vs}) != 1:
            raise ValueError(f"{make} {model}: some numbers aren't in any SPLIT part")
        formerly = sorted({v["formerly"] for v in vs if v.get("formerly")} - {model_id})
        # Specs from the type most of this model's vehicles are, in the city's list.
        in_city = [city_rows[(kind, v["number"])] for v in vs
                   if (kind, v["number"]) in city_rows and not v.get("unlisted")]
        majority = Counter(c["idMarki"] for c in in_city).most_common(1)
        model_specs = specs(types[(kind, majority[0][0])], kind) if majority and (kind, majority[0][0]) in types else None
        # Vehicles of another type with other specs: the 2010 Lion's City Gs are diesel, the
        # 2019-20 ones CNG. Not by batch, since one year's delivery can mix types (Ursus CS2, 2017).
        odd = defaultdict(list)
        for c in in_city if model_specs else []:
            s = specs(types[(kind, c["idMarki"])], kind) if (kind, c["idMarki"]) in types else None
            if s and s != model_specs:
                odd[json.dumps(s, sort_keys=True)].append(int(c["number"]))
        variants = sorted(({"specs": json.loads(s), "numbers": sorted(ns)} for s, ns in odd.items()),
                          key=lambda v: v["numbers"][0])
        liveries = {c["number"]: "suburbanBlue" for c in in_city if c.get("colour") == SUBURBAN_BLUE}
        liveries |= {v["number"]: LIVERIES[(kind, int(v["number"]))] for v in vs if (kind, int(v["number"])) in LIVERIES}
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
            # Works cars are "vintage" too, for app versions before WORKS: those keep them out of
            # the fleet % and the rarity tiers. Newer apps go by "works" and ignore it.
            "vintage": model_id in VINTAGE or split or works or all(v["vintage"] for v in vs),
            "onTest": all(v.get("onTest", False) for v in vs),
            **({"works": True} if works else {}),
            **(dict(zip(("runs", "trial", "runsPl", "trialPl"), TRIALS[(make, model)]))
               if (make, model) in TRIALS else {}),
            **({"specs": model_specs} if model_specs else {}),
            **({"variants": variants} if variants else {}),
            **({"liveries": dict(sorted(liveries.items(), key=lambda kv: int(kv[0])))} if liveries else {}),
            # Ids this model's numbers were filed under before a SPLIT. Older apps ignore it.
            **({"formerly": formerly} if formerly else {}),
        })
    ids = Counter(m["id"] for m in models)
    assert all(c == 1 for c in ids.values()), f"duplicate model ids: {[i for i, c in ids.items() if c > 1]}"
    numbers = {m["id"]: {n for b in m["batches"] for n in b["numbers"]} for m in models}
    for m in models:
        # Trams only: 1000 and 1001 are bus numbers too.
        sets = [list(s) for s in FIXED_SETS if m["kind"] == "TRAM" and set(s) <= numbers[m["id"]]]
        if m["id"] in COUPLED:
            m["coupled"] = True
        if sets:
            m["sets"] = sets
        if m["kind"] == "TRAM" and (trailers := sorted(TRAILERS & numbers[m["id"]])):
            m["trailers"] = trailers
        if m["id"] in TOWING:
            m["tows"] = True
    assert sum(len(m.get("trailers", [])) for m in models) == len(TRAILERS), "a TRAILERS number isn't in the data"
    assert not TOWING - numbers.keys(), f"TOWING ids not in the data any more: {TOWING - numbers.keys()}"
    missing = COUPLED - numbers.keys()
    assert not missing, f"COUPLED ids not in the data any more: {missing}"
    placed = sum(1 for m in models for _ in m.get("sets", []))
    assert placed == len(FIXED_SETS), "a FIXED_SETS pair isn't within one model"
    models.sort(key=lambda m: (m["kind"], -m["fleet"], m["name"]))
    missing = VINTAGE - {m["id"] for m in models}
    assert not missing, f"VINTAGE ids not in the data any more: {missing}"

    depots = sorted({parse_depot(v["depot"]) + (v["kind"],) for v in vehicles if v["depot"]})
    raw = json.loads(RAW.read_text())
    depots = [{"code": c, "name": n, "kind": k} for c, n, k in depots]
    previous = json.loads(OUT.read_text()) if OUT.exists() else None
    # Phones download fleet.json when this beats theirs (a plain string comparison), so it's
    # when the content last changed, to the minute: a second push on the same day still
    # reaches them. A rebuild that changes nothing keeps the old one, so it leaves no diff;
    # --touch stamps it anyway (for a file whose old stamp phones already have).
    if previous and previous["models"] == models and previous["depots"] == depots and "--touch" not in sys.argv:
        fetched = previous["fetched"]
    else:
        fetched = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    city_en = f" and the city's open data (fetched {city['fetched']})" if city else ""
    city_pl = f" i otwarte dane miasta (stan z {city['fetched']})" if city else ""
    # Phones show only the models fleet.json has, so a vanished id hides people's catches.
    if previous and "--allow-drop" not in sys.argv:
        gone = {m["id"] for m in previous["models"]} - {m["id"] for m in models}
        if gone:
            print(f"refusing to write: model ids would disappear: {', '.join(sorted(gone))}\n"
                  "(rerun with --allow-drop if that's on purpose)", file=sys.stderr)
            sys.exit(1)
    OUT.write_text(json.dumps({
        # ZTM is the base; the hand-kept lists above fill its gaps (new deliveries, trial
        # and club buses, names, build years).
        "source": f"Warsaw ZTM vehicle database (fetched {raw['fetched']}){city_en}, plus Warszawikia, "
                  "the KMKM club, TransInfo, phototrans.eu and live GPS",
        "sourcePl": f"Baza pojazdów ZTM Warszawa (stan z {raw['fetched']}){city_pl}, a także Warszawikia, "
                    "klub KMKM, TransInfo, phototrans.eu i GPS na żywo",
        "fetched": fetched,
        "models": models,
        "depots": depots,
    }, ensure_ascii=False, separators=(",", ":")))
    total = sum(m["fleet"] for m in models)
    print(f"wrote {OUT.relative_to(ROOT)}: {len(models)} models, {total} vehicles, {len(depots)} depots")


if __name__ == "__main__":
    if "--scrape" in sys.argv:
        scrape()
    if "--offline" not in sys.argv:
        fetch_city()
    city = load_city()
    build(with_city(load_raw(), city), city)
