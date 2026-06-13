#!/usr/bin/env bash
# Generates dashboard-like query load so the Grafana latency/rows-read
# panels have something to show. Ctrl-C to stop.
set -euo pipefail
AUTH="admin:admin"
URL="http://localhost:8123/"

QUERIES=(
  "SELECT quantile(0.95)(duration_ms) FROM lab.events WHERE site_id = {s} AND event_time > now() - INTERVAL 7 DAY"
  "SELECT country, count() FROM lab.events WHERE event_time > now() - INTERVAL 1 DAY GROUP BY country"
  "SELECT toStartOfHour(event_time) h, count() FROM lab.events WHERE site_id = {s} GROUP BY h ORDER BY h"
  "SELECT count() FROM lab.events_bad WHERE site_id = {s} AND event_time > now() - INTERVAL 7 DAY"
)

echo "Sending a query every ~2s. Watch 'Query latency' and 'Rows read' in Grafana."
while true; do
  q="${QUERIES[$RANDOM % ${#QUERIES[@]}]}"
  q="${q//\{s\}/$((RANDOM % 500))}"
  curl -s -u "$AUTH" "$URL" --data-binary "$q" > /dev/null
  sleep 2
done
