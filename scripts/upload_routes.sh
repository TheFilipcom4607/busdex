#!/bin/sh
# Uploads build/routes.json.gz (from build_routes.py) to the tabor-live Worker, where phones
# fetch it. The GitHub Action does this daily; run it by hand to push a fresh build sooner.
# The token comes from ROUTES_UPLOAD_TOKEN, or from Config/Secrets.xcconfig.
set -eu
cd "$(dirname "$0")/.."
TOKEN="${ROUTES_UPLOAD_TOKEN:-$(sed -n 's/^TABOR_ROUTES_UPLOAD_TOKEN *= *//p' Config/Secrets.xcconfig 2>/dev/null)}"
[ -n "$TOKEN" ] || { echo "No ROUTES_UPLOAD_TOKEN" >&2; exit 1; }
read -r LINES FEED < build/routes.meta
curl --fail-with-body -sS -X PUT \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/gzip" \
  -H "X-Routes-Lines: $LINES" -H "X-Routes-Feed: $FEED" \
  --data-binary @build/routes.json.gz "${ROUTES_URL:-https://taborapi.thefilip.com/v1/routes}"
echo
