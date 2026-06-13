-- ============================================================
-- Validation queries (§8 from runbook)
-- ============================================================

-- Object counts per database
SELECT
    database,
    countIf(engine LIKE '%MergeTree') AS tables,
    countIf(engine = 'View')          AS views
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database
ORDER BY database;

-- All read.* views must contain FINAL
SELECT name
FROM system.tables
WHERE database = 'read'
  AND create_table_query NOT LIKE '%FINAL%';

-- Spot-check row counts through the FINAL layer
SELECT 'hkpug5ii1l25n' AS topic, count() AS rows FROM read.hkpug5ii1l25n
UNION ALL
SELECT 'hkaggineq5gd7',          count()         FROM read.hkaggineq5gd7
UNION ALL
SELECT 'fvow3t4chjeqj',          count()         FROM read.fvow3t4chjeqj;

-- Column count per table (sanity check against §4b)
SELECT
    database,
    table,
    count() AS col_count
FROM system.columns
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database, table
ORDER BY database, table;
