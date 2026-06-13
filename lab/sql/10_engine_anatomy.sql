-- ============================================================
-- 10: ENGINE ANATOMY — see the storage engine with your own eyes
-- ============================================================

-- ---------- A. Parts on disk are just directories ----------
-- Run in your shell, not SQL:
--   docker exec ch ls /var/lib/clickhouse/data/lab/events/
--   docker exec ch ls /var/lib/clickhouse/data/lab/events/<some_part_dir>/
--
-- Inside a WIDE part you'll see, per column:
--   country.bin    compressed column data
--   country.cmrk2  marks: byte offsets into .bin, one per granule (8192 rows)
-- plus: primary.cidx (sparse PK), partition.dat, count.txt, checksums.txt
--
-- Small parts are stored COMPACT (all columns in one data.bin) until
-- min_bytes_for_wide_part (~10MB). Verify which is which:
SELECT name, part_type, rows, formatReadableSize(bytes_on_disk) AS size, level
FROM system.parts
WHERE database = 'lab' AND table = 'events' AND active
ORDER BY rows DESC;
-- 'level' = how many merge generations produced this part. Fresh insert = 0.
-- Part name decoding: partition_minBlock_maxBlock_level

-- ---------- B. Granules and marks: the sparse index, quantified ----------
SELECT
    table,
    sum(marks)                                   AS total_granules,
    sum(rows)                                    AS rows,
    round(sum(rows) / sum(marks))                AS rows_per_granule,
    formatReadableSize(sum(marks) * 24)          AS approx_pk_ram
FROM system.parts
WHERE database = 'lab' AND active
GROUP BY table;
-- The ENTIRE primary index for 20M rows is a few hundred KB in RAM.
-- That's why ClickHouse index lookups are basically free — and why the
-- index can't find individual rows, only skip 8192-row blocks.

-- ---------- C. Watch the mark cache work ----------
SYSTEM DROP MARK CACHE;
SELECT count() FROM lab.events WHERE site_id = 42 FORMAT Null;  -- cold
SELECT count() FROM lab.events WHERE site_id = 42 FORMAT Null;  -- warm

-- Per-query cache hits/misses live in query_log's ProfileEvents map:
SELECT
    event_time,
    query_duration_ms,
    ProfileEvents['MarkCacheHits']   AS mark_hits,
    ProfileEvents['MarkCacheMisses'] AS mark_misses,
    ProfileEvents['SelectedGranules'] AS granules_read,
    ProfileEvents['SelectedParts']    AS parts_read
FROM system.query_log
WHERE type = 'QueryFinish' AND query LIKE '%site_id = 42%' AND query_kind = 'Select'
ORDER BY event_time DESC LIMIT 4;
-- ProfileEvents is the single most underused expert tool: ~400 counters
-- recorded PER QUERY. Diffing them between two query variants tells you
-- exactly where time went. Browse them all: SELECT * FROM system.events;

-- ---------- D. Built-in sampling profiler (poor man's flamegraph) ----------
SET allow_introspection_functions = 1;

SELECT sum(duration_ms) FROM (
    SELECT user_id, count(), avg(duration_ms) AS duration_ms
    FROM lab.events GROUP BY user_id
) SETTINGS query_profiler_real_time_period_ns = 1000000;  -- sample every 1ms

-- Then aggregate the stacks it captured:
SELECT
    count() AS samples,
    arrayStringConcat(arrayMap(x -> demangle(addressToSymbol(x)), trace), '\n') AS stack
FROM system.trace_log
WHERE event_time > now() - INTERVAL 2 MINUTE AND trace_type = 'Real'
GROUP BY trace
ORDER BY samples DESC
LIMIT 3 FORMAT Vertical;
-- You are now reading the C++ call stacks of your own query. Where do the
-- samples land — aggregation? decompression? That tells you what to fix.

-- ---------- E. See the query as the engine sees it ----------
EXPLAIN PLAN actions = 1
SELECT country, count() FROM lab.events WHERE site_id < 10 GROUP BY country;

EXPLAIN PIPELINE
SELECT country, count() FROM lab.events WHERE site_id < 10 GROUP BY country;
-- PIPELINE shows the actual processor graph and thread fan-out (x4, x8...).
-- This is how you verify max_threads and in-order optimizations later.

EXPLAIN ESTIMATE
SELECT country, count() FROM lab.events WHERE site_id < 10 GROUP BY country;
-- Predicted parts/rows/marks to read, without running anything.
