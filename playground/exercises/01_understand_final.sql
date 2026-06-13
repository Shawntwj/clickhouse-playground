-- ============================================================
-- Exercise 1: Understand the SELECT FINAL hotspot
--
-- Goal: see what FINAL actually costs before you fix it.
-- Every query you run here shows up in the Grafana
-- "Query Performance" dashboard → watch it update in real time.
-- ============================================================

-- Step 1: How many duplicate rows exist in each datacapture table?
-- (FINAL deduplicates on read — this is what makes it expensive)
SELECT
    'hkpug5ii1l25n'                                              AS topic,
    (SELECT count() FROM datacapture.hkpug5ii1l25n)             AS raw_rows,
    (SELECT count() FROM datacapture.hkpug5ii1l25n FINAL)       AS final_rows,
    raw_rows - final_rows                                        AS duplicates;

-- Step 2: EXPLAIN the FINAL plan — notice the MergeTreeReadPool steps
EXPLAIN pipeline
SELECT count() FROM datacapture.hkpug5ii1l25n FINAL;

-- Step 3: Run the same query through the read.* view
-- FINAL is inherited — this is what every downstream consumer does
SELECT count() FROM read.hkpug5ii1l25n;

-- Step 4: Time a real aggregation through the FINAL layer
-- Run this a few times — check Grafana for the query_duration_ms
SELECT
    region,
    fuel_type,
    avg(value_mw)  AS avg_mw,
    count()        AS rows
FROM read.hkpug5ii1l25n
GROUP BY region, fuel_type
ORDER BY avg_mw DESC;

-- Step 5: Which tables are accessed most via FINAL right now?
-- (populated after you've run a few queries)
SELECT
    tables[1]                       AS table_name,
    countIf(query LIKE '%FINAL%')   AS final_queries,
    count()                         AS total_queries,
    avg(query_duration_ms)          AS avg_ms,
    max(query_duration_ms)          AS max_ms
FROM system.query_log
WHERE
    event_date = today()
    AND type = 'QueryFinish'
    AND length(tables) > 0
GROUP BY table_name
ORDER BY final_queries DESC
LIMIT 20;
