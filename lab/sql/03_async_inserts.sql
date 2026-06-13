-- ============================================================
-- 03: INSERTS — why "too many parts" happens, and async inserts
-- ============================================================
-- Every INSERT creates a new part (a directory on disk). Background merges
-- combine them. If you insert in tiny batches faster than merges can keep
-- up, parts explode and you eventually get:
--   "Too many parts (N). Merges are processing significantly slower than inserts."
--
-- Rules:
--   1. Best: batch on the client. 10k-500k rows per INSERT, ~1 insert/sec/table.
--   2. Can't batch (many tiny producers)? -> async_insert=1: the SERVER
--      buffers rows and flushes one part per buffer. This is the
--      ClickHouse-native replacement for Kafka-as-a-buffer in small setups.

-- Target table for the stress scripts:
CREATE TABLE IF NOT EXISTS lab.firehose
(
    event_time  DateTime,
    user_id     UInt32,
    site_id     UInt16,
    country     LowCardinality(String),
    url         LowCardinality(String),
    duration_ms UInt16
)
ENGINE = MergeTree
ORDER BY (site_id, event_time);

-- Key async insert settings (sent per-query or set in a profile):
--   async_insert = 1                          -- turn it on
--   wait_for_async_insert = 1                 -- ack AFTER flush (durable, default)
--   wait_for_async_insert = 0                 -- ack immediately (fire-and-forget,
--                                             -- max throughput, can lose the buffer on crash)
--   async_insert_busy_timeout_ms = 1000       -- flush at most every N ms
--   async_insert_max_data_size = 10485760     -- ...or when buffer hits N bytes

-- Watch the buffer live while scripts/insert_storm.sh runs:
SELECT * FROM system.asynchronous_inserts;

-- Count parts as they accumulate / merge away:
SELECT count() AS active_parts
FROM system.parts
WHERE database = 'lab' AND table = 'firehose' AND active;

-- After the storm, see what merges did:
SELECT event_time, merge_reason, rows_read, formatReadableSize(bytes_read_uncompressed) AS read
FROM system.part_log
WHERE database = 'lab' AND table = 'firehose' AND event_type = 'MergeParts'
ORDER BY event_time DESC
LIMIT 20;

-- Cleanup between runs:
-- TRUNCATE TABLE lab.firehose;
