-- ============================================================
-- 44: CLUSTER-WIDE OBSERVABILITY — clusterAllReplicas() patterns
-- ============================================================
-- Prereq: exercises 40 + 41 (or 42) so there's something to observe.
--
-- system.* tables are PER-NODE. Each ClickHouse server has its own
-- query_log, parts, replicas, etc. clusterAllReplicas() is the table
-- function that fans a query out across every node and stitches the
-- results together.

-- ---------- A. Fleet-wide query_log ----------
SELECT
    hostName()           AS host,
    count()              AS queries,
    round(avg(query_duration_ms)) AS avg_ms,
    max(query_duration_ms)        AS max_ms
FROM clusterAllReplicas('cluster_1s2r', system.query_log)
WHERE event_date = today() AND type = 'QueryFinish'
GROUP BY host
ORDER BY host;
-- One row per node. Lets you spot a single slow replica without ssh-ing in.

-- ---------- B. Find queries that fanned out to multiple shards ----------
-- A Distributed query writes ONE row on the initiator and ONE row on each
-- shard that participated. They share `initial_query_id`.
SELECT
    initial_query_id,
    countIf(is_initial_query = 1) AS initiator_rows,
    countIf(is_initial_query = 0) AS shard_rows,
    max(query_duration_ms)        AS slowest_shard_ms,
    sum(read_rows)                AS total_rows_read
FROM clusterAllReplicas('cluster_2s1r', system.query_log)
WHERE event_date = today() AND type = 'QueryFinish'
GROUP BY initial_query_id
HAVING shard_rows > 0
ORDER BY slowest_shard_ms DESC
LIMIT 10;
-- High slowest_shard_ms with low average = one shard is the straggler.
-- Look at THAT shard's host to find the bottleneck.

-- ---------- C. Replication health, fleet-wide ----------
SELECT
    hostName()        AS host,
    database, table,
    queue_size, absolute_delay,
    if(absolute_delay > 60, 'BEHIND', 'ok') AS status
FROM clusterAllReplicas('cluster_1s2r', system.replicas)
WHERE database = 'lab'
ORDER BY absolute_delay DESC;
-- Run this on a schedule. A delay > 60s is usually action-worthy:
-- merge starvation, slow disk, or network partition with Keeper.

-- ---------- D. Parts distribution across replicas ----------
SELECT
    hostName()                AS host,
    database, table,
    count()                   AS active_parts,
    sum(rows)                 AS rows,
    formatReadableSize(sum(bytes_on_disk)) AS size
FROM clusterAllReplicas('cluster_1s2r', system.parts)
WHERE active AND database = 'lab'
GROUP BY host, database, table
ORDER BY host, table;
-- For ReplicatedMergeTree both replicas should be near-identical.
-- A big mismatch in rows = one replica is lagging (correlate with C above).

-- ---------- E. Distributed ingest queue ----------
-- When you INSERT INTO a Distributed table, rows are first written to a
-- spool directory on the initiator, then forwarded to the destination
-- shard. This is the queue:
SELECT
    hostName()  AS host,
    database, table,
    is_blocked, error_count, data_files, formatReadableSize(data_compressed_bytes) AS pending
FROM clusterAllReplicas('cluster_2s1r', system.distributed_queue);
-- error_count climbing = a destination shard is rejecting writes.
-- is_blocked = the queue is paused (manual or after too many errors).

-- ---------- F. Cluster errors & exceptions ----------
SELECT
    hostName()      AS host,
    last_error_time,
    substring(last_error_message, 1, 80) AS err,
    last_error_trace
FROM clusterAllReplicas('cluster_1s2r', system.errors)
WHERE last_error_time > now() - INTERVAL 1 HOUR
ORDER BY last_error_time DESC
LIMIT 10;

-- ---------- G. When you need the central pattern ----------
-- clusterAllReplicas() is fine for ad-hoc and dashboards on a healthy cluster.
-- For long-term retention / fleet history, run a MV on EACH node that ships
-- system.query_log into a centralized table (over a Distributed engine, or
-- to S3, or via Kafka). The "third cluster" pattern: a small observability
-- cluster that ingests metric_log/query_log from prod, queryable for months.
--
-- Sketch:
--   ON each prod node:
--     CREATE MATERIALIZED VIEW obs_pump TO obs_dist AS
--     SELECT hostName() AS host, * FROM system.query_log;
--   obs_dist points at a Distributed table on the obs cluster.
--
-- This is what every team eventually builds. It's also a perfect
-- demonstration of exercises 05 (MV) + 21 (Kafka, optional) + 42 (Distributed).
