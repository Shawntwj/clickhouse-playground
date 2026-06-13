-- ============================================================
-- 06: QUERY TUNING — PREWHERE, skip indexes, projections
-- ============================================================

-- ---------- PREWHERE ----------
-- ClickHouse reads only PREWHERE columns first, filters, then reads the rest
-- for surviving granules. The optimizer usually does this automatically;
-- verify with EXPLAIN and force it when it guesses wrong:
EXPLAIN SYNTAX
SELECT url, duration_ms FROM lab.events
WHERE country = 'JP' AND duration_ms > 4900;
-- Look for "PREWHERE" in the rewritten query.

-- ---------- SKIP INDEXES ----------
-- Secondary indexes that let CH skip granule blocks for columns NOT in the
-- primary key. They help selective predicates only.
ALTER TABLE lab.events ADD INDEX idx_country country TYPE set(100) GRANULARITY 4;
ALTER TABLE lab.events ADD INDEX idx_url url TYPE bloom_filter(0.01) GRANULARITY 4;
ALTER TABLE lab.events MATERIALIZE INDEX idx_country;
ALTER TABLE lab.events MATERIALIZE INDEX idx_url;

EXPLAIN indexes = 1
SELECT count() FROM lab.events WHERE url = '/checkout';
-- Compare granules before/after. Types: minmax (sorted-ish numerics),
-- set(N) (low cardinality), bloom_filter / tokenbf_v1 / ngrambf_v1 (strings).

-- ---------- PROJECTIONS ----------
-- A projection = the same data stored again inside the table with a
-- DIFFERENT order/aggregation. The optimizer picks it automatically.
-- Fixes "my second query pattern doesn't match ORDER BY" without a new table.
ALTER TABLE lab.events ADD PROJECTION by_user
(
    SELECT * ORDER BY user_id, event_time
);
ALTER TABLE lab.events MATERIALIZE PROJECTION by_user;

-- Wait for materialization, then this query (terrible under ORDER BY
-- (site_id, event_time)) becomes index-driven:
SELECT count(), max(event_time) FROM lab.events WHERE user_id = 12345;

EXPLAIN indexes = 1
SELECT count(), max(event_time) FROM lab.events WHERE user_id = 12345;
-- You should see it reading from the projection part.
-- Cost: ~2x storage + slower inserts/merges for this table. A trade, not magic.

-- ---------- SETTINGS THAT MATTER ----------
-- Per query:
--   SETTINGS max_threads = 4                  -- parallelism (default = cores)
--   SETTINGS max_memory_usage = 2000000000    -- fail fast instead of OOM
--   SETTINGS max_bytes_before_external_group_by = 1000000000  -- spill GROUP BY to disk
-- Try a huge GROUP BY with/without external aggregation while watching the
-- Memory panel in Grafana:
SELECT user_id, count() FROM lab.events GROUP BY user_id
FORMAT Null
SETTINGS max_bytes_before_external_group_by = 200000000;

-- ---------- READ YOUR OWN TELEMETRY ----------
-- Top 10 most expensive query shapes (normalized):
SELECT
    normalized_query_hash,
    any(substring(query, 1, 80)) AS sample,
    count()                       AS runs,
    round(avg(query_duration_ms)) AS avg_ms,
    formatReadableSize(avg(memory_usage)) AS avg_mem,
    sum(read_rows)                AS total_rows_read
FROM system.query_log
WHERE type = 'QueryFinish' AND query_kind = 'Select'
GROUP BY normalized_query_hash
ORDER BY sum(query_duration_ms) DESC
LIMIT 10;
