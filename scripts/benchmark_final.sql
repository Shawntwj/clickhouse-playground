-- ============================================================
-- FINAL vs Dictionary benchmark queries (§6 from runbook)
-- Run via: clickhouse-client -h localhost -u admin --password admin < scripts/benchmark_final.sql
-- ============================================================

-- 1. Baseline — cost of FINAL on the dispatch table
SELECT count() FROM datacapture.hkpug5ii1l25n FINAL;

-- 2. Same count through the read.* view (FINAL inherited)
SELECT count() FROM read.hkpug5ii1l25n;

-- 3. EXPLAIN to see FINAL processing cost
EXPLAIN SELECT count() FROM read.hkpug5ii1l25n;

-- 4. Compare FINAL vs non-FINAL row counts (dedup delta)
SELECT
    (SELECT count() FROM datacapture.hkpug5ii1l25n FINAL) AS final_count,
    (SELECT count() FROM datacapture.hkpug5ii1l25n)       AS raw_count,
    raw_count - final_count                               AS duplicate_rows;

-- 5. Example dictionary definition for a small reference table
--    (uncomment and adapt once you have a use case)
-- CREATE DICTIONARY IF NOT EXISTS tech.trading_holiday_dict (
--     date         Date,
--     area         String,
--     calendar     String,
--     holiday_name String,
--     is_partial   UInt8
-- )
-- PRIMARY KEY date, area, calendar
-- SOURCE(CLICKHOUSE(TABLE 'trading_holiday' DB 'tech' USER 'admin' PASSWORD 'admin'))
-- LAYOUT(COMPLEX_KEY_HASHED())
-- LIFETIME(MIN 300 MAX 600);

-- 6. System-level FINAL heatmap (mirrors size_queries.sql §C)
SELECT
    database,
    table,
    query_kind,
    count()           AS query_count,
    avg(query_duration_ms) AS avg_ms
FROM system.query_log
WHERE
    event_date >= today() - 1
    AND has(tables, concat(database, '.', table))
GROUP BY database, table, query_kind
ORDER BY query_count DESC
LIMIT 20;
