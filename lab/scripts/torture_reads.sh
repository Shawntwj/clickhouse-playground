#!/usr/bin/env bash
# READ TORTURE: find your concurrency knee.
# Runs K parallel heavy GROUP BYs for K = 1,2,4,8,16 and prints avg latency.
# Watch Grafana: Query latency p95, Memory, Rows read.
set -euo pipefail
AUTH="admin:admin"
URL="http://localhost:8123/"
Q="SELECT user_id, count(), avg(duration_ms) FROM lab.events GROUP BY user_id FORMAT Null"
THREADS="${THREADS:-2}"   # per-query max_threads; try 8 vs 2 and compare totals

run_one() { curl -s -u "$AUTH" "${URL}?max_threads=${THREADS}" --data-binary "$Q" > /dev/null; }

echo "=== Concurrency storm (max_threads=$THREADS per query) ==="
printf "%-12s %-14s %-16s\n" "parallel" "wall time (s)" "avg latency (s)"
for K in 1 2 4 8 16; do
  start=$(date +%s.%N)
  for _ in $(seq 1 "$K"); do run_one & done
  wait
  end=$(date +%s.%N)
  wall=$(echo "$end - $start" | bc)
  printf "%-12s %-14.2f %-16.2f\n" "$K" "$wall" "$(echo "$wall" | bc -l)"
done

echo
echo "The 'knee' is where wall time stops being flat and starts scaling"
echo "linearly with K — that's your box saturated. Now re-run with"
echo "THREADS=8 ./torture_reads.sh and compare: fat queries saturate sooner."
echo "Defense lives in lab/sql/14_isolation.sql."
