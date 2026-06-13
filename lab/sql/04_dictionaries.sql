-- ============================================================
-- 04: DICTIONARIES — kill your dimension JOINs
-- ============================================================
-- ClickHouse JOINs build the right side in memory per query. For small,
-- slowly-changing dimension tables (sites, customers, geo), a dictionary
-- loads the data ONCE into RAM and lookups become O(1) function calls.

-- A dimension table: 500 sites with metadata.
CREATE TABLE lab.sites
(
    site_id UInt16,
    name    String,
    tier    LowCardinality(String),
    owner   String
)
ENGINE = MergeTree ORDER BY site_id;

INSERT INTO lab.sites
SELECT
    number                                            AS site_id,
    concat('site_', toString(number))                 AS name,
    ['free','pro','enterprise'][1 + number % 3]       AS tier,
    concat('team_', toString(number % 20))            AS owner
FROM numbers(500);

-- The dictionary on top of it:
CREATE DICTIONARY lab.sites_dict
(
    site_id UInt16,
    name    String,
    tier    String,
    owner   String
)
PRIMARY KEY site_id
SOURCE(CLICKHOUSE(DB 'lab' TABLE 'sites' USER 'default' PASSWORD 'lab'))
LAYOUT(HASHED())          -- all in RAM, hashed by key. CACHE() for huge sources.
LIFETIME(MIN 60 MAX 120); -- re-poll source every 60-120s -> near-real-time dims

-- ============================================================
-- BENCHMARK: classic JOIN vs dictGet, 20M-row fact table
-- ============================================================
-- 1) JOIN:
SELECT s.tier, count() AS events, quantile(0.95)(duration_ms) AS p95
FROM lab.events e
INNER JOIN lab.sites s ON e.site_id = s.site_id
GROUP BY s.tier;

-- 2) dictGet:
SELECT dictGet('lab.sites_dict', 'tier', toUInt64(site_id)) AS tier,
       count() AS events,
       quantile(0.95)(duration_ms) AS p95
FROM lab.events
GROUP BY tier;

-- Compare elapsed + memory in the query log:
SELECT query_duration_ms, formatReadableSize(memory_usage) AS mem, substring(query, 1, 60) AS q
FROM system.query_log
WHERE type = 'QueryFinish' AND query ILIKE '%tier%' AND query_kind = 'Select'
ORDER BY event_time DESC LIMIT 4;

-- Bonus: dictionaries auto-refresh (LIFETIME). Update a row in lab.sites,
-- wait ~2 min (or run SYSTEM RELOAD DICTIONARY lab.sites_dict) and the
-- dictGet output changes — no pipeline needed.

-- Inspect dictionary state:
SELECT name, status, element_count, formatReadableSize(bytes_allocated) AS ram
FROM system.dictionaries;
