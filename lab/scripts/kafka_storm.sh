#!/usr/bin/env bash
# Produce N JSON events into the 'events' topic via Redpanda's rpk.
# Watch them flow: Kafka engine -> MV pump -> lab.firehose -> Grafana.
set -euo pipefail
N="${1:-50000}"

docker exec redpanda rpk topic create events -p 3 2>/dev/null || true

echo "Producing $N events to topic 'events'..."
python3 - "$N" <<'EOF' | docker exec -i redpanda rpk topic produce events
import json, random, sys, datetime
n = int(sys.argv[1])
countries = ["US","DE","IN","BR","GB"]
urls = ["/home","/product","/cart","/checkout"]
for i in range(n):
    print(json.dumps({
        "ts": datetime.datetime.now().isoformat(),
        "user_id": random.randrange(1000000),
        "site_id": random.randrange(500),
        "country": random.choice(countries),
        "url": random.choice(urls),
        "duration_ms": random.randrange(5000),
    }))
EOF

echo "Done. Check: SELECT count() FROM lab.firehose"
echo "Lag/errors: SELECT * FROM system.kafka_consumers FORMAT Vertical"
