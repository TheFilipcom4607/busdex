#!/usr/bin/env python3
"""Export Tabor/Resources/fleet.json to data/fleet-models.csv, one row per unbroken run of
fleet numbers of one model, built in one year, at one depot, with one operator: number
range, model, year, count, rarity tier, ZTM code, bus or tram, depot and operator.

fleet.json only keeps a batch's most common depot and a model's operators, so the depot
and operator of each vehicle come from data/ztm-vehicles.json plus the extra vehicles in
fetch_fleet.py, the same rows fleet.json is built from.

Usage:  python3 scripts/export_models_csv.py   # Python 3.12+, like fetch_fleet.py
"""
import csv
import json
from collections import defaultdict
from pathlib import Path

import fetch_fleet

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Tabor" / "Resources" / "fleet.json"
OUT = ROOT / "data" / "fleet-models.csv"


def spans(numbers):
    """[1, 2, 3, 5, 7, 8] -> [(1, 3), (5, 5), (7, 8)]"""
    nums = sorted({int(n) for n in numbers})
    out, start = [], None
    for i, n in enumerate(nums):
        if start is None:
            start = n
        if i + 1 == len(nums) or nums[i + 1] != n + 1:
            out.append((start, n))
            start = None
    return out


def tier(m):
    """Same tiers as Tier in Tabor/Core/Fleet.swift."""
    if m.get("vintage"):
        return "VINTAGE"
    if m.get("onTest"):
        return "ON TEST"
    fleet = m["fleet"]
    return "LEGENDARY" if fleet <= 12 else "GOLD" if fleet <= 48 else "RARE" if fleet <= 80 else "COMMON"


def vehicles():
    """(kind, ZTM code, number) -> (depot, operator) for every vehicle fleet.json is built from."""
    raw = json.loads(fetch_fleet.RAW.read_text())["vehicles"]
    out = {}
    for v in fetch_fleet.with_vintage_extras(raw):
        if not v["number"].isdigit():
            continue
        code = f"{v['make']} {v['model']}".strip()
        depot = " ".join(filter(None, fetch_fleet.parse_depot(v["depot"]))) if v["depot"] else ""
        out[(v["kind"], code, int(v["number"]))] = (depot, fetch_fleet.short_carrier(v["carrier"]))
    return out


def main():
    models = json.loads(SRC.read_text())["models"]
    where = vehicles()
    rows = []
    for m in models:
        groups = defaultdict(list)
        for b in m["batches"]:
            for n in b["numbers"]:
                depot, operator = where[(m["kind"], m["code"], n)]
                groups[(b.get("year"), depot, operator)].append(n)
        for (year, depot, operator), numbers in groups.items():
            for lo, hi in spans(numbers):
                rows.append({
                    "number range": str(lo) if lo == hi else f"{lo}-{hi}",
                    "model and make": m["name"],
                    "year": year or "",
                    "count": hi - lo + 1,
                    "rarity": tier(m),
                    "ztm code": m["code"],
                    "type": m["kind"].lower(),
                    "depot": depot,
                    "operator": operator,
                    "_sort": (m["kind"] != "TRAM", lo),
                })
    rows.sort(key=lambda r: r.pop("_sort"))
    with OUT.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} ranges -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
