# TABOR

SwiftUI app for collecting Warsaw buses and trams. The fleet lives in `Tabor/Resources/fleet.json`, which `scripts/fetch_fleet.py` generates from the ZTM vehicle database (raw scrape in `data/ztm-vehicles.json`) plus hand-kept lists at the top of the script. Never edit `fleet.json` by hand.

## Adding a bus the ZTM database doesn't list (yet)

Work out which kind it is, then add it to the matching list in `scripts/fetch_fleet.py`:

| Kind | List | Effect |
|---|---|---|
| New regular delivery, already in service | `EXTRA_BUSES` (make, model, number, operator, year, depot) | Joins a model, counts toward the fleet % |
| Trial / demo bus | `TEST_BUSES` (make, model, number, operator, depot, where it runs, trial label such as `"ON TRIAL SEP 2026"`) | ON TEST tier, own book section, outside the fleet % and set badges |
| Preserved / club bus | `EXTRA_VINTAGE_BUSES` (make, model, number, owner, year) | VINTAGE tier |
| Retired but still listed | `RETIRED` | Dropped |

- To join an existing model, copy ZTM's exact make/model spelling from `data/ztm-vehicles.json`. Depots use ZTM's raw string, e.g. `'R-1 "Woronicza" (R-07)'`.
- Only add numbers a source confirms, or that you've seen in the live feed. Don't extrapolate a whole range from an order size.
- ZTM's own row wins once it lists a number, so hand-added entries retire themselves.
- Spotter names go in `DISPLAY_NAMES`. A model's id is a slug of ZTM's make/model, so renaming is safe. Moving a vehicle to another make/model (`MERGE`) changes its model id, and existing catches of it lose their page.
- If a source doesn't confirm a model name, number range or year, ask the user rather than guess.

Then run:

```bash
python3 scripts/fetch_fleet.py --offline && swift test
```

## Finding and checking new buses

- **Live GPS vs fleet data** is the quickest way to spot unlisted or trial buses: fetch `busestrams_get` (key: `TABOR_UM_KEY` in the gitignored `Config/Secrets.xcconfig`; `type=1` bus, `type=2` tram). Keep rows whose `Time` is within 10 minutes of the newest one, and list the `VehicleNumber`s missing from `fleet.json`.
- **ZTM lookup for one number:** `fetch_fleet.scrape_list({"ztm_traction": 1, "ztm_vehicle_number": "959"})`.
- **Sources:**
  - Warszawikia (`warszawa.fandom.com`) has per-model number tables. Read it in the built-in browser; WebFetch gets a 402.
  - TransInfo (`transinfo.pl/infobus`) reports trials and deliveries.
  - kmkm.waw.pl has a build year on each club bus's page.
  - phototrans.eu sits behind a Cloudflare bot check, so rely on search results for it.
- **Test the change in the iPhone 18 Pro simulator, then install on the user's phone:**

```bash
xcodebuild -project Tabor.xcodeproj -scheme Tabor -destination 'id=00008140-001475100CBB001C' -derivedDataPath build/device -allowProvisioningUpdates build
```

```bash
xcrun devicectl device install app --device 00008140-001475100CBB001C build/device/Build/Products/Debug-iphoneos/Tabor.app
```
