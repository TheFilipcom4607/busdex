#!/usr/bin/env python3
"""Exit 0 if a freshly built fleet.json differs from the committed one in anything but its
date, 1 if only the date moved, 2 if the new snapshot looks broken (so CI never commits it).

Usage:  python3 scripts/fleet_changed.py   # compares the working copy with HEAD
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATH = "Tabor/Resources/fleet.json"


def content(d):
    return {k: v for k, v in d.items() if k not in ("source", "fetched")}


new = json.loads((ROOT / PATH).read_text())
old = json.loads(subprocess.run(["git", "show", f"HEAD:{PATH}"], cwd=ROOT, check=True,
                                capture_output=True, text=True).stdout)

total = lambda d: sum(m["fleet"] for m in d["models"] if not m.get("vintage"))
# A half-failed scrape shrinks the fleet; real retirements never take out a tenth of it in a week.
if not new.get("fetched") or len(new["models"]) < 40 or total(new) < 0.9 * total(old):
    print(f"refusing: {len(new['models'])} models, {total(new)} vehicles (was {total(old)})", file=sys.stderr)
    sys.exit(2)
if any(m["fleet"] != sum(len(b["numbers"]) for b in m["batches"]) for m in new["models"]):
    print("refusing: a model's fleet doesn't match its batches", file=sys.stderr)
    sys.exit(2)

if content(new) == content(old):
    print("fleet unchanged")
    sys.exit(1)
print(f"fleet changed: {total(old)} → {total(new)} vehicles, {len(old['models'])} → {len(new['models'])} models")
