#!/usr/bin/env python3
"""Export one row per model from Tabor/Resources/fleet.json to data/fleet-models.csv:
fleet number ranges, count and production years.

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


def main():
    models = json.loads(SRC.read_text())["models"]
    rows = []
    for m in models:
        numbers = [n for b in m["batches"] for n in b["numbers"]]
        years = sorted({b["year"] for b in m["batches"] if b.get("year")})
        status = "trial" if m.get("onTest") else "vintage" if m.get("vintage") else "in service"
        rows.append({
            "kind": m["kind"],
            "model": m["name"],
            "make": m["make"],
            "ztm_code": m["code"],
            "status": status,
            "count": len(numbers),
            "first_year": m.get("firstYear") or "",
            "last_year": m.get("lastYear") or "",
            "batch_years": ", ".join(map(str, years)),
            "number_ranges": ranges(numbers),
            "operators": ", ".join(m["operators"]),
        })
    rows.sort(key=lambda r: (r["kind"] != "TRAM", r["status"] != "in service", -r["count"], r["model"]))
    with OUT.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print(f"{len(rows)} models -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
