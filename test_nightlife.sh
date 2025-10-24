#!/usr/bin/env bash
# test_nightlife.sh  (v2)
PROJECT="blackappios"
REGION="us-central1"
FN="rssEventbriteNightlife"
BASE="https://${REGION}-${PROJECT}.cloudfunctions.net/${FN}"

DAYS="${DAYS:-21}"   # override like:  DAYS=30 ./test_nightlife.sh
LINES="${LINES:-200}"

# city *tokens* that your function understands
CITIES=(charlotte atlanta maryland vegas nyc lagos douala capetown)

hit() {
  local key="$1"
  local url="${BASE}?city=${key}&days=${DAYS}"
  echo "🔎  ${key}"
  echo "    URL: ${url}"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${url}")
  local items
  items=$(curl -s --max-time 10 "${url}" | grep -c '<item>')
  echo "    HTTP ${code} • items=${items}"
}

logs() {
  echo "🪵 Last ${LINES} lines (filtered) for ${FN}:"
  firebase functions:log --only "${FN}" -P "${PROJECT}" --lines "${LINES}" \
    | egrep 'EBRSS|TMRSS|HTTP|withImage|fallback|Missing EVENTBRITE_TOKEN' || true
}

echo "===================="
echo "RSS smoke tests (DAYS=${DAYS})"
echo "===================="
for c in "${CITIES[@]}"; do
  hit "${c}"
done
echo
logs
echo
echo "💡 Tips:"
echo "  • Change DAYS:  DAYS=30 ./test_nightlife.sh"
echo "  • More logs:    LINES=500 ./test_nightlife.sh"

