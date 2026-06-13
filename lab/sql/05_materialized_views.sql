-- ============================================================
-- 05: MATERIALIZED VIEWS — the engine of cheap real-time
-- ============================================================
-- An MV is an INSERT trigger: every block written to the source table is
-- transformed and written to a target table. Pay the aggregation cost ONCE
-- at insert time, then your dashboard reads thousands of rows, not millions.

-- Target: per-minute, per-site rollup.
CREATE TABLE lab.events_1m
(
    minute      DateTime,
    site_id     UInt16,
    events      UInt64,
    duration_q  AggregateFunction(quantile(0.95), UInt16)
)
ENGINE = AggregatingMergeTree
ORDER BY (site_id, minute);

CREATE MATERIALIZED VIEW lab.events_1m_mv TO lab.events_1m AS
SELECT
    toStartOfMinute(event_time)               AS minute,
    site_id,
    count()                                   AS events,
    quantileState(0.95)(duration_ms)          AS duration_q
FROM lab.firehose            -- attach to the live ingest table
GROUP BY minute, site_id;

-- Backfill history (MVs only see NEW inserts):
INSERT INTO lab.events_1m
SELECT toStartOfMinute(event_time), site_id, count(), quantileState(0.95)(duration_ms)
FROM lab.events
GROUP BY 1, 2;

-- ============================================================
-- BENCHMARK: dashboard query, raw vs rollup
-- ============================================================
-- Raw (scans millions of rows):
SELECT toStartOfMinute(event_time) AS m, count(), quantile(0.95)(duration_ms)
FROM lab.events
WHERE event_time > now() - INTERVAL 6 HOUR
GROUP BY m ORDER BY m;

-- Rollup (scans a few thousand pre-aggregated rows):
SELECT minute, sum(events), quantileMerge(0.95)(duration_q)
FROM lab.events_1m
WHERE minute > now() - INTERVAL 6 HOUR
GROUP BY minute ORDER BY minute;

-- NOW THE FEEDBACK LOOP:
-- 1. Run scripts/insert_storm.sh async in a terminal.
-- 2. In Grafana, add a panel on lab.events_1m with 5s refresh:
--      SELECT minute AS time, sum(events) AS events
--      FROM lab.events_1m
--      WHERE minute >= $__fromTime GROUP BY minute ORDER BY minute
-- 3. Watch your inserts appear in the rollup within ~1-2 seconds.
--    That IS near-real-time analytics: async inserts -> MV -> tiny reads.

-- Rules of thumb:
--  * Use -State / -Merge combinators for quantiles, uniq, etc.
--  * SummingMergeTree is a simpler MV target if you only need counts/sums.
--  * Chain: one raw table, several MVs (per-minute, per-hour, per-day).
--  * MVs run inside the insert: a heavy MV slows ingestion. Keep them lean.
