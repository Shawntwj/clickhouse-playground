# ClickHouse Playground

Local replica of a production ClickHouse Cloud v26.2.1 cluster, with Grafana for exploration. Built from the runbook in `RECREATE.md`.

## Stack

| Service | URL | Credentials |
|---------|-----|-------------|
| ClickHouse HTTP | http://localhost:8123 | admin / admin |
| ClickHouse Play UI | http://localhost:8123/play | admin / admin |
| Grafana | http://localhost:3000 | admin / admin |

## Quick start

```bash
# Start everything
docker compose up -d

# Wait for ClickHouse to be healthy, then seed data
clickhouse-client -h localhost -u admin --password admin < scripts/seed_data.sql

# Open Grafana → Energy Dispatch dashboard is pre-provisioned
open http://localhost:3000
```

## Project structure

```
init/
  01_databases.sql     — 14 databases mirroring production
  02_tables.sql        — OSS-engine base tables (SharedReplacingMergeTree → ReplacingMergeTree)
  03_read_views.sql    — read.* FINAL views (the SELECT FINAL hotspot)
  04_derived_views.sql — curated au/nz/dim layers
  05_roles.sql         — inco_reader role (SELECT on read.* only)

scripts/
  seed_data.sql        — synthetic data generation (scaled down from prod)
  validate.sql         — §8 validation queries from runbook
  benchmark_final.sql  — FINAL vs dictionary benchmarks (§6 from runbook)

grafana/
  provisioning/        — auto-wired ClickHouse datasource
  dashboards/          — Energy Dispatch dashboard (provisioned on startup)

config/clickhouse/
  users.xml            — admin + replica_reader users
```

## Engine mapping (OSS vs Cloud)

| Production (Cloud) | Local (OSS) |
|--------------------|-------------|
| `SharedReplacingMergeTree` | `ReplacingMergeTree` |
| `SharedMergeTree` | `MergeTree` |

## Key experiments from the runbook

### SELECT FINAL hotspot (§6)
All 982 `read.*` views are `SELECT * FROM datacapture.<topic> FINAL`. Run the benchmark:
```bash
clickhouse-client -h localhost -u admin --password admin < scripts/benchmark_final.sql
```

### Dictionary vs FINAL (§4a)
Small reference tables (`tech.trading_holiday`, `utl.kafka_crossdb_connectors`, etc.) are
prime candidates for ClickHouse dictionaries. The `benchmark_final.sql` script has a commented
dictionary DDL template ready to adapt.

### LowCardinality strings (§5)
Production has 0 `LowCardinality` columns — adding it to categorical `String` columns
(`region`, `fuel_type`, `run_type`) is a quick win to test compression/speed gains.

## Tear down

```bash
docker compose down -v   # -v removes named volumes (all data)
```
