# ClickHouse Playground

Two tracks sharing one ClickHouse + Grafana stack.

> **New here?** Open [`overview.html`](overview.html) first — one page covering how ClickHouse works, why each exercise exists, and which path to take based on what you're trying to do.

| Track | What it is | Database(s) | README | Visual walkthroughs |
|-------|------------|-------------|--------|---------------------|
| **`playground/`** | Local replica of a production ClickHouse Cloud cluster. Energy-dispatch data, ReplacingMergeTree, the `SELECT FINAL` hotspot. | `au`, `nz`, `jp`, `mdm`, `datacapture`, `read`, ... | [`playground/README.md`](playground/README.md) | [`playground/docs/index.html`](playground/docs/index.html) |
| **`lab/`** | Beginner→pro course. ORDER BY, codecs, async inserts, dictionaries, MVs, projections, TTL, integrations (Kafka/Postgres), finance tick store, ML feature factory. | `lab` | [`lab/README.md`](lab/README.md) | [`lab/docs/exercises/index.html`](lab/docs/exercises/index.html) |

## Setup

```bash
brew install colima docker docker-compose
colima start --cpu 4 --memory 8 --disk 40

make up                 # ClickHouse + Grafana
make playground-seed    # prod-replica datacapture data
make seed               # lab course: 20M synthetic web events
```

| Service | URL | Credentials |
|---------|-----|-------------|
| ClickHouse HTTP / Play UI | http://localhost:8123/play | admin / admin |
| Grafana | http://localhost:3000 | admin / admin |

The ClickHouse container is capped at 4 GB so the memory-pressure exercises in `lab/sql/13_read_warfare.sql` actually feel like pressure.

## Integrations (opt-in)

`lab/sql/20..22` need Redpanda (Kafka-compatible) and Postgres. Bring them up with:

```bash
make up-integrations
make kafka-storm        # produce 50k JSON events into topic 'events'
```

## Cluster track (opt-in)

`lab/sql/40..45` need a 2-node ClickHouse cluster + Keeper for coordination. Adds ~1.5 GB to your Colima allocation.

```bash
make up-cluster         # ch-keeper + ch-1 + ch-2
make cluster-status     # verify wiring
make sql-1              # interactive client on ch-1
make sql-2              # interactive client on ch-2
```

Covers ON CLUSTER DDL, ReplicatedMergeTree, Distributed/sharding, `clusterAllReplicas()` observability, and why sharded FINAL is silently wrong. See [`lab/docs/exercises/index.html`](lab/docs/exercises/index.html) → Cluster section.

## Layout

```
.
├── docker-compose.yml              shared ClickHouse + Grafana
├── docker-compose.integrations.yml opt-in Redpanda + Postgres
├── Makefile                        all the targets
├── init/                           auto-runs on first boot:
│                                     creates 14 prod-replica DBs + `lab`
│                                     + prod-replica tables, views, roles
├── playground/                     prod-replica FINAL track
│   ├── exercises/                  01..04 FINAL/dictionary exercises
│   ├── scripts/                    seed_data, validate, benchmark_final
│   ├── docs/                       expert guide + EXPLAIN walkthroughs
│   └── README.md
├── lab/                            beginner→pro course
│   ├── sql/                        01..07 fundamentals · 10..14 expert
│                                     · 20..22 integrations · 30..31 finance/ML
│   ├── scripts/                    insert_storm, torture_*, query_load, kafka_storm
│   ├── postgres/init.sql           seed for the postgres sync exercise
│   ├── docs/                       PRIMER, WALKTHROUGH, EXPERT
│   └── README.md
└── grafana/
    ├── provisioning/               datasource + dashboard provider
    └── dashboards/
        ├── energy_dispatch.json    playground
        ├── query_performance.json  playground
        └── feedback_loop.json      lab
```

## Useful commands

```bash
make help                 # list everything
make sql                  # interactive client
make load                 # background SELECTs (drives lab Grafana panels)
make storm-sync           # break it: tiny sync inserts
make storm-async          # fix it: async inserts
make playground-bench     # FINAL vs dictionary
make clean                # tear down + delete data
```
