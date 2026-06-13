#!/usr/bin/env bash
# Fire 2000 tiny single-row inserts at ClickHouse over HTTP.
# Usage:
#   ./insert_storm.sh sync    -> one part per insert. Watch "Active parts" climb.
#   ./insert_storm.sh async   -> server buffers + flushes. Parts stay flat.
#
# Run it, then stare at the Grafana dashboard (5s refresh):
#   - "Active parts" panel
#   - "Merges running" panel
#   - "Async insert flushes / sec" panel
set -euo pipefail

MODE="${1:-async}"
N="${2:-2000}"
URL="http://localhost:8123/"
AUTH="admin:admin"

if [ "$MODE" = "sync" ]; then
  PARAMS=""
  echo ">>> SYNC mode: $N inserts = up to $N new parts. This may eventually error with 'Too many parts' — that's the lesson."
else
  PARAMS="&async_insert=1&wait_for_async_insert=0&async_insert_busy_timeout_ms=1000"
  echo ">>> ASYNC mode: server buffers rows, flushes ~1 part/sec."
fi

for i in $(seq 1 "$N"); do
  q="INSERT INTO lab.firehose VALUES (now(), $((RANDOM % 100000)), $((RANDOM % 500)), 'US', '/home', $((RANDOM % 5000)))"
  curl -s -u "$AUTH" "${URL}?query=$(python3 - <<EOF
import urllib.parse; print(urllib.parse.quote("""$q"""))
EOF
)${PARAMS}" -X POST > /dev/null &
  # limit concurrency a bit
  if (( i % 50 == 0 )); then wait; echo "  $i inserts sent"; fi
done
wait
echo "Done. Check: SELECT count() FROM system.parts WHERE table='firehose' AND active;"
