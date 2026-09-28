#!/usr/bin/env python3
"""Export Tabor/Resources/fleet.json to data/fleet-models.csv, one row per unbroken run of
fleet numbers of one model built in one year: number range, model, year, count, rarity tier,
ZTM code and whether it's a bus or a tram.

Usage:  python3 scripts/export_models_csv.py
"""
import csv
import json
from collections import defaultdict
from pathlib import Path

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


# Same tiers as Tier in Tabor/Core/Fleet.swift.
RANK = {t: i for i, t in enumerate(["COMMON", "RARE", "GOLD", "LEGENDARY", "VINTAGE", "ON TEST"])}


def tier(m):
    if m.get("vintage"):
        return "VINTAGE"
    if m.get("onTest"):
        return "ON TEST"
    fleet = m["fleet"]
    return "LEGENDARY" if fleet <= 12 else "GOLD" if fleet <= 48 else "RARE" if fleet <= 80 else "COMMON"


def main():
    models = json.loads(SRC.read_text())["models"]
    rows = []
    for m in models:
        by_year = defaultdict(list)  # a year can come in several batches, one per depot
        for b in m["batches"]:
            by_year[b.get("year")] += b["numbers"]
        for year, numbers in by_year.items():
            for lo, hi in spans(numbers):
                rows.append({
                    "number range": str(lo) if lo == hi else f"{lo}-{hi}",
                    "model and make": m["name"],
                    "year": year or "",
                    "count": hi - lo + 1,
                    "rarity": tier(m),
                    "ztm code": m["code"],
                    "type": m["kind"].lower(),
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
