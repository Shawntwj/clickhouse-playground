CH = docker exec -i clickhouse clickhouse-client -u admin --password admin
CH_TTY = docker exec -it clickhouse clickhouse-client -u admin --password admin
CH1 = docker exec -i ch-1 clickhouse-client -u admin --password admin
CH1_TTY = docker exec -it ch-1 clickhouse-client -u admin --password admin
CH2_TTY = docker exec -it ch-2 clickhouse-client -u admin --password admin

.PHONY: help up up-integrations up-cluster down down-cluster clean sql sql-1 sql-2 ps logs cluster-status \
        seed load storm-sync storm-async torture-ingest torture-reads kafka-storm \
        playground-seed playground-bench playground-validate

help:           ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---- stack ----
up:             ## Start ClickHouse + Grafana
	docker compose up -d
	@echo
	@echo "ClickHouse: http://localhost:8123/play   (admin / admin)"
	@echo "Grafana:    http://localhost:3000        (admin / admin)"

up-integrations: ## Add Redpanda (Kafka) + Postgres, for lab/sql/20..22
	docker compose -f docker-compose.yml -f docker-compose.integrations.yml up -d

up-cluster:     ## Add Keeper + ch-1 + ch-2 for the cluster track (lab/sql/40..45)
	docker compose -f docker-compose.yml -f docker-compose.cluster.yml up -d
	@echo
	@echo "ch-1: http://localhost:8124  (admin / admin)"
	@echo "ch-2: http://localhost:8125  (admin / admin)"
	@echo "Cluster check: make cluster-status"

down:           ## Stop containers (keep volumes)
	docker compose down

down-cluster:   ## Stop cluster containers only
	docker compose -f docker-compose.yml -f docker-compose.cluster.yml down

clean:          ## Stop and delete volumes — wipes all data
	docker compose down -v

sql:            ## Interactive clickhouse-client (single-node)
	$(CH_TTY)

sql-1:          ## Interactive client on ch-1 (cluster node)
	$(CH1_TTY)

sql-2:          ## Interactive client on ch-2 (cluster node)
	$(CH2_TTY)

cluster-status: ## Verify cluster wiring + Keeper connectivity
	$(CH1) -q "SELECT cluster, shard_num, replica_num, host_name, is_local FROM system.clusters WHERE cluster LIKE 'cluster_%' ORDER BY cluster, shard_num, replica_num FORMAT PrettyCompact"
	@echo
	$(CH1) -q "SELECT 'ch-1 sees Keeper' AS check, count() AS keeper_nodes FROM system.zookeeper WHERE path = '/' FORMAT PrettyCompact"

ps:             ## Container status
	docker compose ps

logs:           ## Tail ClickHouse logs
	docker compose logs -f clickhouse

# ---- lab course (lab.* DB) ----
seed:           ## Lab exercise 01: 20M synthetic web events
	$(CH) --multiquery < lab/sql/01_seed_and_order_by.sql || true

load:           ## Background SELECT load for Grafana latency panels
	bash lab/scripts/query_load.sh

storm-sync:     ## 2000 tiny sync INSERTs — watch Active parts climb
	bash lab/scripts/insert_storm.sh sync

storm-async:    ## Same inserts via async_insert — parts stay flat
	bash lab/scripts/insert_storm.sh async

torture-ingest: ## Benchmark ingestion format ladder (rows/sec)
	bash lab/scripts/torture_ingest.sh

torture-reads:  ## Concurrency storm — find saturation knee
	bash lab/scripts/torture_reads.sh

kafka-storm:    ## Produce N JSON events to Redpanda (needs up-integrations)
	bash lab/scripts/kafka_storm.sh

# ---- playground (prod-replica) ----
playground-seed: ## Seed datacapture.* + reference tables (~750k rows)
	$(CH) --multiquery < playground/scripts/seed_data.sql

playground-bench: ## SELECT FINAL vs dictionary benchmarks
	$(CH) --multiquery < playground/scripts/benchmark_final.sql

playground-validate: ## §8 validation queries
	$(CH) --multiquery < playground/scripts/validate.sql
