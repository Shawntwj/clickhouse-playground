# EXPERT TRACK — the engine, and how to abuse it

Prereq: you've done `README.md` exercises 01–07. This track is exercises `sql/10–14` plus two torture scripts. The theme changes from "use ClickHouse well" to "understand the machine well enough to push it to its limits — and know exactly which limit you hit."

```
the expert loop:
  form a hypothesis ─► hit the engine hard ─► read its telemetry
        ▲                                          │
        └──── ProfileEvents / trace_log / parts ◄──┘
```

---

## 1. The engine in four sentences (exercise 10)

1. A table is a set of **immutable parts**; a part is **one compressed file per column** plus a **sparse index** (one entry per 8192-row granule) small enough to always sit in RAM.
2. Reads = use the index to pick granules → use **marks** to seek into column files → decompress only those blocks → stream them through a **processor pipeline** across threads.
3. Writes = sort the block, write a brand-new part; **background merges** continuously fold parts together (LSM-style levels).
4. Everything the engine does increments one of ~400 **ProfileEvents counters, recorded per query** — the engine narrates itself if you read `system.query_log`, `trace_log`, `part_log`.

Exercise 10 makes each sentence physical: you `ls` a part directory, count granules, diff mark-cache hits between cold and warm runs, capture the C++ stacks of your own query with the built-in sampling profiler, and read `EXPLAIN PIPELINE` to see the thread fan-out. Once `ProfileEvents` diffing is in your hands, you never guess "why is this slow" again — that one habit is most of expertise.

## 2. Drive the merge machine (exercise 11)

`SYSTEM STOP MERGES` + the insert storm = you reproduce "Too many parts" on demand, watch backpressure kick in (`parts_to_delay_insert`), hit the throw threshold, then release merges and watch the avalanche in `system.merges` and the Grafana parts panel. You'll also learn the expert lifecycle toolkit: partition `DROP/DETACH/ATTACH` (instant, metadata-only — the reason `PARTITION BY` exists), scheduled `OPTIMIZE ... PARTITION ... FINAL`, and why mutations (`ALTER DELETE/UPDATE`) are the slow path you design to never need.

## 3. Ingestion warfare (exercise 12 + `make torture-ingest`)

The throughput ladder, worst to best: `VALUES` → CSV/JSON → RowBinary → **Native** → server-side `INSERT SELECT`. The torture script benchmarks the ladder on your box and prints rows/sec — the server-side number is your **hardware ceiling**; every gap below it is parsing/transport overhead you can claw back.

The dirty tricks:
- **Null engine + MVs** — ingest an unbounded stream, store *only* rollups. 10M events in, ~500 rows on disk. The ultimate heavy-ingestion-on-a-budget pattern, and one MV per rollup fans a single stream out N ways.
- **Buffer engine** — RAM shock absorber when you can't change clients *and* reads must see data instantly (crash loses the buffer; know that trade).
- Settings: `max_insert_threads`, `min_insert_block_size_rows`, `input_format_parallel_parsing`; backfills loaded per-partition so merges stay local.

## 4. Read warfare (exercise 13 + `make torture-reads`)

- **Query cache** (`use_query_cache=1`): whole-result caching with TTL. Twenty dashboard viewers become one real query per TTL — this plus rollups *is* the no-autoscaling architecture.
- **In-order aggregation/reading**: when `GROUP BY`/`ORDER BY` match the table's sort key, the engine streams instead of building hash tables — near-zero memory on huge groupings. Proof is in the ProfileEvents diff.
- **SAMPLE BY**: 1/10 of the data, ~10x the speed, statistically honest if you sample by user. Exploration rarely needs exact counts.
- **FINAL-dodging** on ReplacingMergeTree: naive count (wrong) vs `FINAL` vs parallel `FINAL` vs `argMax` self-dedup — you time all four.
- **Aggregate projections**: a rollup hidden *inside* the table, used automatically; `force_optimize_projection=1` to prove it fired.
- **Thread economics**: the torture script sweeps 1→16 parallel heavy queries and finds your saturation knee; then you discover the counterintuitive law — capping per-query `max_threads` *raises* total throughput on a busy box.

## 5. Abuse-proofing (exercise 14)

Real experts break things in ways that degrade gracefully. You create an `analyst` user with a settings profile (memory ceiling, time limit, thread cap), run a deliberately monstrous query as them, and watch it die at exactly 1.5 GB while ingestion doesn't blink. Quotas, query priorities, `KILL QUERY`. The fixed-box doctrine at the end of the file is the philosophical core: caps give you a *known worst case*, which is the thing autoscaling charges you monthly to avoid knowing.

---

## The expert's table of contents to the engine

| You want to know... | Look at |
|---|---|
| why a query was slow | `system.query_log` → `ProfileEvents` diff between variants |
| where CPU actually went | `system.trace_log` + `query_profiler_real_time_period_ns` |
| how parallel a query really ran | `EXPLAIN PIPELINE` |
| what it *will* read before running | `EXPLAIN ESTIMATE`, `EXPLAIN indexes=1` |
| insert/merge health | `system.parts` (levels!), `system.part_log`, `system.merges` |
| who is hurting the box right now | `system.processes`, then `KILL QUERY` |
| what a setting actually does | `system.settings` / `system.merge_tree_settings` (`description` column) |

## Drills (repeat until boring)

1. Take any slow query → `EXPLAIN indexes=1` → name the exact reason (granules, parts, memory, threads) → fix it → prove the fix in ProfileEvents.
2. Reproduce "Too many parts" from memory, then resolve it three ways (batching, async_insert, stop/start merges).
3. Take a raw-table dashboard query → make it ≥100x cheaper (MV or projection) → verify with `force_optimize_projection` / rows-read panel.
4. Run both torture scripts, change one knob, predict the new numbers *before* running. Wrong prediction = the gap in your model; go find it.
5. Saturate the box with reads while ingesting — keep p95 ingestion latency flat using only profiles/quotas/priorities.

When step 4's predictions start landing, you're not guessing anymore. That's the whole job.
