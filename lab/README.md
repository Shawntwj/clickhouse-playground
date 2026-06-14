# ClickHouse Optimization Lab — Beginner to Pro

A hands-on course in one repo. Every concept has an exercise, and every exercise has a Grafana panel so you can *see* what ClickHouse is doing instead of guessing. The end state: near-real-time analytics on one fixed-size box — no autoscaling bill.

> **Visual walkthroughs:** [`docs/exercises/index.html`](docs/exercises/index.html) — one page per exercise with diagrams, expected output, gotchas. Open it in a browser.

```
 your terminal                 the feedback loop
 ─────────────                 ─────────────────
 insert storm  ──►  ClickHouse  ──►  system.metric_log / query_log / parts
 query load    ──►      │                       │
                        ▼                       ▼
                  materialized views ──►  Grafana (5s refresh)
                                          "what the hell is going on"
```

---

## 0. Setup

```bash
# Install Docker Desktop, launch it once, then bump memory to 6 GB+
# (Settings → Resources). 8 GB if you plan to use the cluster track.
# From the repo root (clickhouse-playground/):
make up        # or: docker compose up -d
```

- ClickHouse SQL playground: http://localhost:8123/play — user `admin`, password `admin`
- Grafana: http://localhost:3000 → dashboard **Feedback Loop** (login `admin` / `admin`)
- CLI client: `make sql`

Seed 20M rows of fake web events:

```bash
make seed      # runs lab/sql/01_seed_and_order_by.sql, ~1 min
```

Keep the dashboard open on a second screen for the rest of this guide. Run `make load` in a spare terminal whenever you want the latency panels to move.

---

## 1. The mental model (read this once, everything else follows)

ClickHouse is not a B-tree database. A MergeTree table is:

```
table
 ├── part_2026_06_1_1_0/        ← immutable directory, one per INSERT (until merged)
 │     ├── site_id.bin          ← each COLUMN is its own compressed file
 │     ├── event_time.bin
 │     ├── ...
 │     └── primary.idx          ← SPARSE index: one entry per 8192 rows ("granule")
 ├── part_2026_06_2_2_0/
 └── ...   background merges combine parts into bigger parts forever
```

Three consequences drive ~90% of all optimization:

1. **Columns are files.** Narrow types and good compression = less I/O = faster everything. (§3)
2. **The index is sparse.** ClickHouse never finds a row; it *skips granules* of 8192 rows. If your `ORDER BY` doesn't match your queries, it skips nothing and scans everything. (§2)
3. **Every INSERT makes a part.** Tiny frequent inserts create thousands of parts and merges drown. (§4)

```
query:  WHERE site_id = 42 AND event_time > now() - 7d

ORDER BY (site_id, event_time)         ORDER BY user_id
┌──┬──┬──┬──┬──┬──┬──┬──┐              ┌──┬──┬──┬──┬──┬──┬──┬──┐
│  │  │██│██│  │  │  │  │              │██│██│██│██│██│██│██│██│
└──┴──┴──┴──┴──┴──┴──┴──┘              └──┴──┴──┴──┴──┴──┴──┴──┘
 reads 2 granules                       reads all granules
```

---

## 2. Exercise 01 — ORDER BY (the biggest single win)

File: `lab/sql/01_seed_and_order_by.sql` (already run by `make seed`). Now run the two benchmark queries at the bottom of the file in `/play`.

What to look at:
- Client output: elapsed time and "X rows read" — expect ~100x difference between `events` and `events_bad`.
- `EXPLAIN indexes = 1` → the `Granules: selected/total` line is the truth.
- Grafana → **Rows read per SELECT** panel: run each query a few times and watch the average jump.

Rules of thumb for choosing `ORDER BY`:
- Put columns you **filter by** first, ordered **low cardinality → high cardinality** (e.g. `(tenant_id, site_id, event_time)`).
- Time usually goes last among the filter columns, not first — most queries filter by entity *and* time.
- `PARTITION BY` is for data lifecycle (drops, TTL), not query speed. `toYYYYMM(...)` is the safe default; hundreds of partitions = you over-partitioned.
- You can't change `ORDER BY` later without rebuilding. Spend your design time here.

---

## 3. Exercise 02 — Types, LowCardinality, codecs

File: `lab/sql/02_types_and_codecs.sql`. Run the `system.columns` query and compare the two tables column by column. Then check the **Parts & compression per table** panel.

The greatest hits:
- `LowCardinality(String)` for any string with < ~10k distinct values (country, url path, status). Dictionary-encodes the column; smaller and faster to GROUP BY.
- Smallest integer that fits: `UInt16` site_id beats `UInt64`.
- Codecs: `Delta`/`DoubleDelta` for timestamps and counters, `Gorilla` for slowly-changing floats, `T64` for small ints, then `ZSTD` on top. `LZ4` (default) = faster, `ZSTD` = smaller.
- Avoid `Nullable` unless NULL truly differs from a sentinel — it adds a hidden bitmap file per column.

Mini-challenge in the file: beat the `events` table's compression ratio with `events_tuned`.

---

## 4. Exercise 03 — Inserts and async inserts (the parts war)

Files: `lab/sql/03_async_inserts.sql` + `lab/scripts/insert_storm.sh`.

```bash
make storm-sync     # 2000 single-row INSERTs, one part each
```
Watch in Grafana: **Active parts** climbs steeply, **Merges running** maxes out, and the server burns CPU just cleaning up your mess. Push N higher and you'll hit the famous `Too many parts` error — now you've *seen* why it happens instead of meeting it at 3am.

```bash
docker exec clickhouse clickhouse-client -u admin --password admin -q "TRUNCATE TABLE lab.firehose"
make storm-async    # same 2000 inserts with async_insert=1
```
Watch: **Active parts** stays flat, **Async insert flushes / sec** ticks ~1/sec. Same data, ~2000x fewer parts.

```
sync:   2000 clients ──► 2000 INSERTs ──► 2000 parts ──► merge storm
async:  2000 clients ──► server buffer ──► flush every 1s ──► ~1 part/sec
```

The decision tree:
1. **Can you batch on the client?** Do that. 10k–500k rows per INSERT, ≤ ~1 insert/sec/table. Nothing beats it.
2. **Many small producers you don't control?** `async_insert=1`. Choose durability:
   - `wait_for_async_insert=1` → client ack after flush (safe, default)
   - `wait_for_async_insert=0` → ack immediately (max throughput; a crash loses the in-memory buffer)
3. Tune the flush with `async_insert_busy_timeout_ms` (your real-time latency floor) and `async_insert_max_data_size`.

This is the budget replacement for "stick Kafka in front of it" at small-to-medium scale.

---

## 5. Exercise 04 — Dictionaries (stop JOINing dimensions)

File: `lab/sql/04_dictionaries.sql`.

A ClickHouse JOIN builds its right side in memory *per query*. A dictionary loads the dimension table into RAM *once* and refreshes itself on a `LIFETIME` schedule, turning enrichment into an O(1) `dictGet()` call.

```
JOIN:    every query:  read sites → hash it → probe 20M rows
dictGet: once a minute: refresh dict ──► queries just do hash lookups
```

Run both benchmark queries, then compare `query_duration_ms` and `memory_usage` in the query-log query provided. Typical result on this dataset: dictGet is several times faster and allocates far less.

When to use what:
- Dictionary: small/medium, slowly changing, keyed lookups (sites, users, geo, feature flags). `LAYOUT(HASHED())` in RAM; `CACHE()` if the source is huge; `LIFETIME` gives you near-real-time dimension updates for free.
- JOIN: ad-hoc analysis, large-to-large joins, anything not key-value shaped.

---

## 6. Exercise 05 — Materialized views (cheap real-time)

File: `lab/sql/05_materialized_views.sql`.

An MV is an insert trigger, not a cached query:

```
INSERT block ──► lab.firehose (raw, TTL 7 days)
        │
        └─MV──► lab.events_1m (per-minute AggregatingMergeTree, kept 13 months)
                       ▲
                Grafana reads THIS, never the raw table
```

Run both benchmark queries: the raw scan touches millions of rows; the rollup touches thousands. Then do the live loop described in the file: `make storm-async` in one terminal, a Grafana panel on `events_1m` with 5s refresh in the other. Your inserts show up aggregated within a second or two. **Async inserts → MV → rollup reads is the whole near-real-time architecture.**

Notes that save you pain:
- MVs see only **new** inserts — backfill the target manually (the file shows how).
- Use `-State` when writing and `-Merge` when reading aggregate functions (`quantileState` / `quantileMerge`).
- MVs execute inside the insert; heavy MV logic slows ingestion. Chain rollups (minute → hour → day) instead of one monster.
- `SummingMergeTree` is the simpler target when you only need counts/sums.

---

## 7. Exercise 06 — Query tuning: PREWHERE, skip indexes, projections

File: `lab/sql/06_query_tuning.sql`.

- **PREWHERE**: read the filter column first, the rest only for surviving granules. Usually automatic — verify with `EXPLAIN SYNTAX`.
- **Skip indexes**: secondary indexes that prune granules for non-key columns. `minmax` for numerics, `set(N)` for low-cardinality, `bloom_filter`/`tokenbf_v1` for strings. They only help *selective* filters — measure with `EXPLAIN indexes=1` before keeping one.
- **Projections**: the same table stored again in a different order (or pre-aggregated), picked automatically by the optimizer. The fix for "my second query pattern fights my ORDER BY". Costs storage and insert speed — a trade, not magic.
- **Settings**: `max_threads`, `max_memory_usage` (fail fast), `max_bytes_before_external_group_by` (spill big GROUP BYs to disk). Run the big GROUP BY in the file while watching the **Memory tracked** panel.

And the meta-skill — ClickHouse profiles itself in SQL:

| Question | Table |
|---|---|
| Which queries are slow / heavy? | `system.query_log` (the file has a "top 10 query shapes" query) |
| Why is this table slow? | `system.parts`, `system.columns` |
| Are merges keeping up? | `system.merges`, `system.part_log` |
| Is async insert buffering? | `system.asynchronous_inserts` |
| What's happening *right now*? | `system.processes`, `system.metric_log` |

---

## 8. Exercise 07 — TTL + rollups: real-time without the cloud bill

File: `lab/sql/07_ttl_and_cost.sql`.

The autoscaling trap: raw data grows forever → dashboard scans grow → cloud scales up → invoice scales up. The fixed-box answer:

```
                 hot, small, fast
 raw events ───► TTL 7 days, recompress at 1 day
      │
      └──MVs──► minute rollup  ─ TTL 13 months
                hour rollup    ─ TTL 5 years
```

- Raw data is a **buffer for debugging and re-aggregation**, not the product.
- Dashboards only ever read rollups → query cost is constant no matter how traffic grows.
- `TTL ... RECOMPRESS CODEC(ZSTD(6))` squeezes warm data; `TTL ... TO VOLUME 'cold'` ships old parts to S3 in prod.
- The capacity math in the file: 20M events/day ≈ 400 MB/day raw, and the rollup is a few MB/day. A 4–8 GB box handles this with the memory limit we set in docker-compose — which is also why the Memory panel matters: you tune to a ceiling instead of paying to remove it.

Other self-hosted cost levers: per-user `quotas` and `max_memory_usage_for_user` so one analyst can't OOM ingestion; `max_concurrent_queries`; one decently-sized server before any cluster (ClickHouse vertically scales absurdly well).

---

## 9. The pro checklist

Schema (decided once, pays forever):
- [ ] `ORDER BY` matches the dominant filter pattern, low→high cardinality
- [ ] `LowCardinality`, tight ints, no reflexive `Nullable`
- [ ] Codecs on timestamps/counters/gauges
- [ ] `PARTITION BY` monthly-ish, used for TTL/drops only

Ingestion:
- [ ] Batched inserts or `async_insert=1` — never raw tiny inserts
- [ ] **Active parts** panel flat or sawtoothing, never climbing
- [ ] MVs lean; rollups chained

Queries:
- [ ] Dashboards read rollups, never raw
- [ ] Dimensions via dictionaries, not JOINs
- [ ] `EXPLAIN indexes=1` shows real granule pruning
- [ ] No `SELECT *` on wide tables

Cost:
- [ ] TTL on raw data; recompress/tier old parts
- [ ] Memory limits + quotas instead of autoscaling
- [ ] `system.query_log` reviewed for the top offenders, weekly

---

## Command reference

```bash
make up            # start the stack
make seed          # 20M-row dataset (exercise 01)
make sql           # clickhouse-client shell
make storm-sync    # break it: tiny sync inserts
make storm-async   # fix it: async inserts
make load          # background SELECTs for latency panels
make clean         # tear down + delete data
```

Exercises live in `lab/sql/01..07` (with expert-track exercises in `lab/sql/10..14`, integrations in `20..22`, and finance/ML in `30..31`), in order. Each ends with the system-table queries that prove (or disprove) the improvement. If a `metric_log` column name errors on your ClickHouse version, list what exists: `DESCRIBE system.metric_log`.
