-- ============================================================
-- 02: SCHEMA = STORAGE = SPEED (types, LowCardinality, codecs)
-- ClickHouse reads columns from disk; smaller columns -> faster everything.
-- ============================================================

-- Compare per-column compression between the two tables from exercise 01:
SELECT
    table,
    name AS column,
    type,
    formatReadableSize(data_compressed_bytes)   AS compressed,
    formatReadableSize(data_uncompressed_bytes) AS uncompressed,
    round(data_uncompressed_bytes / data_compressed_bytes, 2) AS ratio
FROM system.columns
WHERE database = 'lab' AND table IN ('events', 'events_bad')
ORDER BY table, data_compressed_bytes DESC;

-- Things to notice:
--  * country String vs LowCardinality(String): LC stores a tiny dictionary
--    + integer indexes. Massive win for columns with < ~10k distinct values.
--  * event_time with CODEC(Delta, ZSTD): timestamps stored as differences
--    compress far better than absolute values.
--  * UInt16 vs UInt64 for duration_ms: 4x fewer raw bytes before compression.

-- Codec cheat sheet (specialized codec first, then a general one):
--   Delta / DoubleDelta -> timestamps, counters, sorted-ish ints
--   Gorilla             -> floats that change slowly (gauges)
--   T64                 -> ints that use few of their bits
--   ZSTD(1..3)          -> general purpose default; LZ4 = faster, larger
-- Anti-patterns: Nullable(...) everywhere (extra bitmap file per column,
-- slows reads) — prefer a sentinel like 0/'' when semantics allow.

-- Mini-exercise: build a third variant and beat the 'events' table's ratio.
CREATE TABLE lab.events_tuned AS lab.events
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (site_id, event_time);

ALTER TABLE lab.events_tuned MODIFY COLUMN event_time DateTime CODEC(DoubleDelta, ZSTD(3));

INSERT INTO lab.events_tuned SELECT * FROM lab.events;

-- Re-run the system.columns query above with table = 'events_tuned'.
-- Then check the "Parts & compression" panel in Grafana.
