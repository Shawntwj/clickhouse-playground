-- ============================================================
-- 13: READ WARFARE — caches, in-order tricks, sampling, FINAL-dodging
-- ============================================================

-- ---------- A. The three caches you control ----------
-- 1. Mark cache (exercise 10) — automatic, prewarm with FORMAT Null queries.
-- 2. Uncompressed block cache — off by default, gold for hot small queries:
SELECT count() FROM lab.events WHERE site_id = 42
SETTINGS use_uncompressed_cache = 1;
-- 3. QUERY CACHE — whole-result caching, the dashboard cheat code:
SELECT country, count() FROM lab.events GROUP BY country
SETTINGS use_query_cache = 1, query_cache_ttl = 60;
-- Run twice; second run is ~0ms. 20 Grafana users on a 10s-refresh
-- dashboard = 1 real query per TTL instead of 120. This single setting
-- is half of "real-time dashboards without autoscaling".
SELECT * FROM system.query_cache;

-- ---------- B. In-order aggregation: GROUP BY that never builds a hash table ----------
-- If GROUP BY keys are a prefix of ORDER BY, CH can stream-aggregate:
SELECT site_id, count(), avg(duration_ms)
FROM lab.events GROUP BY site_id
SETTINGS optimize_aggregation_in_order = 1;
-- Compare ProfileEvents/memory vs the same query with the setting = 0:
SELECT query_duration_ms, formatReadableSize(memory_usage) AS mem,
       ProfileEvents['ExternalAggregationWritePart'] AS spilled
FROM system.query_log
WHERE type = 'QueryFinish' AND query LIKE '%GROUP BY site_id%'
ORDER BY event_time DESC LIMIT 4;
-- Same trick for ORDER BY: optimize_read_in_order=1 makes
-- "ORDER BY site_id, event_time DESC LIMIT 100" read ~100 rows, not 20M.

-- ---------- C. Sampling: trade accuracy for 10-100x speed ----------
CREATE TABLE lab.events_sampled
(
    event_time DateTime, user_id UInt32, site_id UInt16,
    country LowCardinality(String), url LowCardinality(String), duration_ms UInt16
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (site_id, intHash32(user_id), event_time)
SAMPLE BY intHash32(user_id);

INSERT INTO lab.events_sampled SELECT * FROM lab.events;

SELECT country, count() * 10 AS est_events       -- scale up by 1/sample
FROM lab.events_sampled SAMPLE 1/10
GROUP BY country;
-- Sampling is BY USER here, so per-user funnels stay coherent inside the
-- sample. Exploration / percentile dashboards rarely need exact counts.

-- ---------- D. FINAL is a tax — three ways to dodge it ----------
-- ReplacingMergeTree dedups on merge, i.e. EVENTUALLY. Reads must
-- deduplicate themselves or accept duplicates.
CREATE TABLE lab.user_state
(
    user_id UInt32, plan LowCardinality(String),
    updated_at DateTime, version UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY user_id;

INSERT INTO lab.user_state SELECT number, 'free',  now() - 100, 1 FROM numbers(1000000);
INSERT INTO lab.user_state SELECT number, 'pro',   now(),       2 FROM numbers(500000);

-- naive (wrong: counts duplicates):
SELECT plan, count() FROM lab.user_state GROUP BY plan;
-- 1) FINAL (correct, slower — dedups at read time):
SELECT plan, count() FROM lab.user_state FINAL GROUP BY plan;
-- 2) FINAL, parallelized properly:
SELECT plan, count() FROM lab.user_state FINAL GROUP BY plan
SETTINGS do_not_merge_across_partitions_select_final = 1, max_final_threads = 4;
-- 3) argMax — dedup yourself, often fastest and works on any engine:
SELECT plan, count() FROM (
    SELECT user_id, argMax(plan, version) AS plan
    FROM lab.user_state GROUP BY user_id
) GROUP BY plan;
-- Time all three via system.query_log. Production rule: dashboards use a
-- pre-deduped MV; FINAL stays in ad-hoc land.

-- ---------- E. Aggregate projections: the rollup hidden inside the table ----------
ALTER TABLE lab.events ADD PROJECTION daily_country
(
    SELECT toDate(event_time) AS d, country, count(), avg(duration_ms)
    GROUP BY d, country
);
ALTER TABLE lab.events MATERIALIZE PROJECTION daily_country;
-- Once materialized, this exact aggregation pattern reads the tiny
-- projection automatically — like an MV, but invisible to your queries:
SELECT toDate(event_time) AS d, country, count()
FROM lab.events GROUP BY d, country ORDER BY d
SETTINGS force_optimize_projection = 1;   -- error if NOT used = your proof

-- ---------- F. Thread abuse, both directions ----------
-- One analyst query at max_threads=8 starves your dashboard queries.
SELECT user_id, count() FROM lab.events GROUP BY user_id FORMAT Null
SETTINGS max_threads = 1;   -- vs 8. Time both, then run scripts/torture_reads.sh
-- Counterintuitive expert move: on a busy box, CAPPING analyst threads
-- raises total throughput. Concurrency beats single-query speed.
