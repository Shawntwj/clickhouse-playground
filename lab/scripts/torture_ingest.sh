#!/usr/bin/env bash
# INGESTION TORTURE: measure rows/sec up the format ladder.
# Watch Grafana: Inserted rows/sec, Memory, Merges, Active parts.
set -euo pipefail
CH() { docker exec -i clickhouse clickhouse-client -u admin --password admin "$@"; }
N="${1:-10000000}"

CH -q "CREATE TABLE IF NOT EXISTS lab.torture AS lab.firehose"
CH -q "TRUNCATE TABLE lab.torture"

bench() {
  local label="$1"; shift
  local start end secs
  start=$(date +%s.%N)
  "$@"
  end=$(date +%s.%N)
  secs=$(echo "$end - $start" | bc)
  printf "%-34s %12.0f rows/sec\n" "$label" "$(echo "$N / $secs" | bc -l)"
  CH -q "TRUNCATE TABLE lab.torture"
}

GEN="SELECT now() - toIntervalSecond(rand() % 3600), rand() % 1000000, rand() % 500,
     ['US','DE','IN'][1 + rand() % 3], ['/home','/cart'][1 + rand() % 2], rand() % 5000
     FROM numbers_mt($N)"

echo "=== Ingestion ladder, $N rows each ==="

# 1. Server-side INSERT SELECT — the hardware ceiling
bench "1. INSERT SELECT (server-side)" \
  CH -q "INSERT INTO lab.torture $GEN SETTINGS max_insert_threads=4"

# 2. Native format over the wire (client -> server)
bench "2. Native format via pipe" bash -c \
  "docker exec clickhouse clickhouse-client -u admin --password admin -q \"$GEN FORMAT Native\" \
   | docker exec -i clickhouse clickhouse-client -u admin --password admin -q 'INSERT INTO lab.torture FORMAT Native'"

# 3. CSV over the wire (text parsing cost)
bench "3. CSV via pipe" bash -c \
  "docker exec clickhouse clickhouse-client -u admin --password admin -q \"$GEN FORMAT CSV\" \
   | docker exec -i clickhouse clickhouse-client -u admin --password admin -q 'INSERT INTO lab.torture FORMAT CSV'"

echo
echo "Lesson: the gap between (1) and (3) is pure parsing+transport overhead."
echo "Re-run with different max_insert_threads / min_insert_block_size_rows."
echo "Then check merge fallout: SELECT count() FROM system.parts WHERE table='torture' AND active"
