-- ============================================================
-- 21: KAFKA PIPELINE — the canonical streaming integration
-- ============================================================
-- Requires: make up-integrations  (starts Redpanda, Kafka-compatible)
-- Create the topic first, in your shell:
--   docker exec redpanda rpk topic create events -p 3
--
-- The pattern is ALWAYS three pieces:
--
--   Kafka topic ──► Kafka ENGINE table ──► MV (the pump) ──► MergeTree
--                   (a consumer,            transforms +      (storage)
--                    not storage)           validates
--
-- The Kafka table holds nothing; reading from it consumes messages.
-- The MV is what continuously pulls and writes. No MV = no ingestion.

-- 1. The consumer:
CREATE TABLE lab.kafka_events
(
    ts          String,            -- arrive loose, parse in the MV
    user_id     UInt32,
    site_id     UInt16,
    country     String,
    url         String,
    duration_ms UInt16
)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'redpanda:9092',
         kafka_topic_list = 'events',
         kafka_group_name = 'clickhouse',
         kafka_format = 'JSONEachRow',
         kafka_num_consumers = 1;

-- 2. The pump (parse, cast, route into the SAME table all other
--    exercises use — one storage table, many ingestion paths):
CREATE MATERIALIZED VIEW lab.kafka_pump TO lab.firehose AS
SELECT
    parseDateTimeBestEffort(ts) AS event_time,
    user_id, site_id, country, url, duration_ms
FROM lab.kafka_events;

-- 3. Produce! In your shell:  make kafka-storm
--    Then watch lab.firehose grow and the Grafana panels move:
SELECT count(), max(event_time) FROM lab.firehose;

-- ---------- Operations you must know ----------
-- Consumer lag / errors:
SELECT database, table, num_messages_read, last_exception_time, exceptions.text
FROM system.kafka_consumers FORMAT Vertical;

-- Bad message handling — don't let one poison message stall the stream:
--   kafka_handle_error_mode = 'stream' exposes _error/_raw_message virtual
--   columns; route failures to a dead-letter table with a second MV.

-- Pause/resume (e.g. for schema changes): DETACH/ATTACH the Kafka table.
DETACH TABLE lab.kafka_events;
ATTACH TABLE lab.kafka_events;
-- Offsets live in Kafka under the consumer group, so this is safe.

-- Replay from scratch: drop the consumer group in the broker
-- (docker exec redpanda rpk group delete clickhouse) and re-attach.

-- ---------- Why this beats a custom consumer service ----------
-- Exactly-once-ish into one table, zero extra processes to deploy, and the
-- MV gives you a SQL transformation layer (cast, enrich via dictGet,
-- filter, fan out to multiple targets) at ingestion time. Most companies'
-- "streaming pipeline" is these three CREATE statements.
