#!/usr/bin/env python3
"""Export one row per model from Tabor/Resources/fleet.json to data/fleet-models.csv:
fleet number ranges, production years, count, rarity tier and ZTM code.

Usage:  python3 scripts/export_models_csv.py
"""
import csv
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Tabor" / "Resources" / "fleet.json"
OUT = ROOT / "data" / "fleet-models.csv"


def ranges(numbers):
    """[1, 2, 3, 5, 7, 8] -> '1-3, 5, 7-8'"""
    nums = sorted(int(n) for n in numbers)
    out, start = [], None
    for i, n in enumerate(nums):
        if start is None:
            start = n
        if i + 1 == len(nums) or nums[i + 1] != n + 1:
            out.append(str(start) if start == n else f"{start}-{n}")
            start = None
    return ", ".join(out)


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
        numbers = [n for b in m["batches"] for n in b["numbers"]]
        first, last = m.get("firstYear"), m.get("lastYear")
        rows.append({
            "number range": ranges(numbers),
            "model and make": m["name"],
            "year": "" if not first else str(first) if first == last else f"{first}-{last}",
            "count": len(numbers),
            "rarity": tier(m),
            "ztm code": m["code"],
            "_sort": (m["kind"] != "TRAM", RANK[tier(m)], -len(numbers), m["name"]),
        })
    rows.sort(key=lambda r: r.pop("_sort"))
    with OUT.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} models -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
