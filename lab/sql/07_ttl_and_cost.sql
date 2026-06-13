-- ============================================================
-- 07: TTL + ROLLUPS = real-time on a fixed-size box
-- ============================================================
-- The cloud-autoscaling trap: keeping raw data forever and scanning it for
-- dashboards forces scale-ups. The self-hosted answer: raw data is a
-- short-lived buffer; rollups are the long-term product.

-- Keep raw events 7 days, then drop. Rollups (events_1m) keep 13 months.
ALTER TABLE lab.firehose MODIFY TTL event_time + INTERVAL 7 DAY;
ALTER TABLE lab.events_1m MODIFY TTL minute + INTERVAL 13 MONTH;

-- TTL can also AGGREGATE instead of delete, or recompress old data:
-- ALTER TABLE lab.firehose MODIFY TTL
--     event_time + INTERVAL 1 DAY RECOMPRESS CODEC(ZSTD(6)),
--     event_time + INTERVAL 7 DAY DELETE;

-- Column-level TTL: drop only the heavy column, keep the row:
-- ALTER TABLE lab.firehose MODIFY COLUMN url LowCardinality(String)
--     TTL event_time + INTERVAL 2 DAY;

-- Tiered storage (prod pattern, not in this lab): hot data on NVMe,
-- old parts moved to S3 via storage policies:
--   TTL event_time + INTERVAL 3 DAY TO VOLUME 'cold'
-- One small box + S3 routinely replaces an autoscaling cluster for
-- dashboard-style workloads.

-- ============================================================
-- Capacity math (why this stays cheap):
--   raw: 20M events/day * ~20 bytes compressed = ~400 MB/day, 7d = ~3 GB
--   1-minute rollup: 500 sites * 1440 min = 720k rows/day = a few MB/day
--   Dashboards hit the rollup -> constant cost regardless of traffic spikes.
-- ============================================================

-- Force TTL evaluation now (normally runs with merges):
OPTIMIZE TABLE lab.firehose FINAL;

-- Verify:
SELECT table, min(min_date) AS oldest, max(max_date) AS newest, sum(rows) AS rows
FROM system.parts WHERE database = 'lab' AND active GROUP BY table;
