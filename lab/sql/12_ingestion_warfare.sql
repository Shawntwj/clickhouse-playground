-- ============================================================
-- 12: INGESTION WARFARE — how hard can one box swallow?
-- ============================================================

-- ---------- A. The throughput ladder ----------
-- Cost per row, highest to lowest:
--   1. INSERT ... VALUES over HTTP      (SQL parsing per row — worst)
--   2. CSV / JSONEachRow                (text parsing, parallel-parsed)
--   3. RowBinary                        (no text parsing)
--   4. Native                           (server's own block format, ~zero cost)
--   5. INSERT ... SELECT server-side    (no network, no parsing — the ceiling)
-- scripts/torture_ingest.sh runs this ladder and prints rows/sec for each.

-- The ceiling test by hand: synthesize rows inside the server.
INSERT INTO lab.firehose
SELECT now() - toIntervalSecond(rand() % 3600),
       rand() % 1000000, rand() % 500,
       ['US','DE','IN'][1 + rand() % 3],
       ['/home','/cart'][1 + rand() % 2],
       rand() % 5000
FROM numbers_mt(50000000)
SETTINGS max_insert_threads = 4, max_threads = 4;
-- Note rows/sec in the client output. THIS is your hardware's limit;
-- everything slower than this is your pipeline's fault, not ClickHouse's.

-- Key insert settings:
--   max_insert_threads            parallel part writers (CPU for speed)
--   min_insert_block_size_rows    bigger blocks = fewer, bigger parts
--   input_format_parallel_parsing text formats parse on multiple cores
--   insert_deduplicate = 0        skip dedup-hash bookkeeping (Replicated tables)

-- ---------- B. The Null engine trick: ingest infinitely, store nothing ----------
-- ENGINE = Null swallows inserts and discards them — but MATERIALIZED VIEWS
-- attached to it STILL FIRE. So: raw stream in, only rollups stored.
CREATE TABLE lab.blackhole AS lab.firehose ENGINE = Null;

CREATE MATERIALIZED VIEW lab.blackhole_1m_mv TO lab.events_1m AS
SELECT toStartOfMinute(event_time) AS minute, site_id,
       count() AS events, quantileState(0.95)(duration_ms) AS duration_q
FROM lab.blackhole
GROUP BY minute, site_id;

INSERT INTO lab.blackhole
SELECT now(), rand() % 1000000, rand() % 500, 'US', '/home', rand() % 5000
FROM numbers_mt(10000000);

SELECT minute, sum(events) FROM lab.events_1m
WHERE minute >= toStartOfMinute(now()) GROUP BY minute;
-- 10M events ingested, ~500 rows stored. Storage cost: effectively zero.
-- This is THE extreme-volume pattern: metrics, ad impressions, IoT — when
-- you only ever need aggregates, never store the raw stream at all.
-- (Variant: Null + several MVs = one stream fanned out to N rollups.)

-- ---------- C. The Buffer engine: RAM shock absorber ----------
-- Pre-async-insert era trick, still useful when you can't change clients
-- AND need the buffer queryable:
CREATE TABLE lab.firehose_buffer AS lab.firehose
ENGINE = Buffer(lab, firehose, 16,
                10, 100,        -- min/max seconds before flush
                10000, 1000000, -- min/max rows
                1000000, 10000000); -- min/max bytes
-- Writes go to lab.firehose_buffer; RAM chunks flush to lab.firehose when
-- any max threshold hits. SELECTs on the buffer see RAM + disk combined.
-- Trade-offs vs async_insert: crash loses the buffer, no PK order in RAM.
-- Modern default: prefer async_insert; reach for Buffer when reads must
-- see data the same millisecond it arrives.

-- ---------- D. Abuse-grade pattern summary ----------
-- many tiny producers -> async_insert -> MergeTree            (default)
-- insane volume, aggregates only -> Null + MVs                 (store nothing)
-- must read instantly + can't batch -> Buffer                  (RAM shield)
-- bulk loads/backfills -> Native format or INSERT SELECT,
--     max_insert_threads up, and load PER PARTITION so merges stay local
