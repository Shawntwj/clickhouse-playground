-- ============================================================
-- 01: SEED DATA + THE SINGLE BIGGEST OPTIMIZATION: ORDER BY
-- ============================================================
CREATE DATABASE IF NOT EXISTS lab;

-- "Naive" table: types are lazy, ORDER BY is an afterthought.
CREATE TABLE lab.events_bad
(
    event_time  DateTime,
    user_id     UInt64,
    site_id     UInt64,
    country     String,
    url         String,
    duration_ms UInt64
)
ENGINE = MergeTree
ORDER BY user_id;   -- high-cardinality first = sparse index can't prune much

-- "Good" table: low-cardinality prefix, time second, tight types, codecs.
CREATE TABLE lab.events
(
    event_time  DateTime CODEC(Delta, ZSTD),
    user_id     UInt32,
    site_id     UInt16,
    country     LowCardinality(String),
    url         LowCardinality(String),
    duration_ms UInt16 CODEC(T64, ZSTD)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (site_id, event_time);   -- matches our query pattern: "site X over time"

-- 20M rows of fake web traffic (last 30 days). ~30-60s on a laptop.
INSERT INTO lab.events_bad
SELECT
    now() - toIntervalSecond(rand() % 2592000)                          AS event_time,
    rand() % 1000000                                                    AS user_id,
    rand() % 500                                                        AS site_id,
    ['US','DE','IN','BR','GB','FR','JP','MX','AU','CA'][1 + rand() % 10] AS country,
    ['/home','/product','/cart','/checkout','/search','/account'][1 + rand() % 6] AS url,
    rand() % 5000                                                       AS duration_ms
FROM numbers(20000000);

INSERT INTO lab.events SELECT * FROM lab.events_bad;

-- ============================================================
-- NOW COMPARE. Same question, both tables:
-- "p95 latency for site 42 in the last 7 days"
-- ============================================================
SELECT quantile(0.95)(duration_ms)
FROM lab.events_bad
WHERE site_id = 42 AND event_time > now() - INTERVAL 7 DAY;

SELECT quantile(0.95)(duration_ms)
FROM lab.events
WHERE site_id = 42 AND event_time > now() - INTERVAL 7 DAY;

-- Look at "Elapsed" and "rows read" in the client output, then prove WHY:
EXPLAIN indexes = 1
SELECT quantile(0.95)(duration_ms)
FROM lab.events
WHERE site_id = 42 AND event_time > now() - INTERVAL 7 DAY;
-- ^ Note "Granules: X/Y" — the primary key skipped most of the table.

EXPLAIN indexes = 1
SELECT quantile(0.95)(duration_ms)
FROM lab.events_bad
WHERE site_id = 42 AND event_time > now() - INTERVAL 7 DAY;
-- ^ Nearly all granules selected = full scan.

-- The receipts, from the query log:
SELECT
    query_duration_ms,
    read_rows,
    formatReadableSize(read_bytes) AS read,
    tables
FROM system.query_log
WHERE type = 'QueryFinish' AND query_kind = 'Select'
  AND has(tables, 'lab.events') OR has(tables, 'lab.events_bad')
ORDER BY event_time DESC
LIMIT 10;
