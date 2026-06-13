-- ============================================================
-- 41: ReplicatedMergeTree — the storage engine with HA built in
-- ============================================================
-- Prereq: exercise 40 (cluster up, lab DB exists on both nodes)
--
-- ReplicatedMergeTree writes each part to ZooKeeper/Keeper, which then
-- coordinates replication to the OTHER replicas of the same shard.
-- It also gives you INSERT DEDUPLICATION for free (Keeper hashes the block).

-- ---------- A. Create a replicated table on cluster_1s2r ----------
CREATE TABLE lab.events ON CLUSTER cluster_1s2r
(
    event_time  DateTime,
    user_id     UInt32,
    site_id     UInt16,
    country     LowCardinality(String),
    url         LowCardinality(String),
    duration_ms UInt16
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/lab/events',   -- Keeper path, shared by all replicas of this shard
    '{replica}'                                 -- per-node identifier (ch-1 / ch-2)
)
ORDER BY (site_id, event_time);
-- Substitutions: both nodes have {shard}=01 (same shard, different replicas).
-- {replica} differs per node → each replica registers under its own name.

-- ---------- B. Insert on ch-1, query on ch-2 (or vice versa) ----------
-- Run this on ch-1:
INSERT INTO lab.events
SELECT
    now() - toIntervalSecond(rand() % 3600),
    rand() % 1000000, rand() % 500,
    ['US','DE','IN'][1 + rand() % 3],
    ['/home','/cart'][1 + rand() % 2],
    rand() % 5000
FROM numbers(100000);

-- Then on ch-2 (use `make sql-2`):
--   SELECT count() FROM lab.events;
-- Expect 100000. Replication is typically sub-second on a healthy local cluster.

-- ---------- C. Watch replication state ----------
SELECT
    table, replica_name, is_leader,
    absolute_delay, queue_size, log_pointer
FROM system.replicas
WHERE database = 'lab' AND table = 'events';
-- queue_size > 0 + climbing absolute_delay = this replica is behind.
-- is_leader: in newer versions, all replicas can lead — older versions
-- had a single leader doing merge coordination.

-- Inspect the Keeper coordination tree for this table:
SELECT name, ctime FROM system.zookeeper
WHERE path = '/clickhouse/tables/01/lab/events';
-- You'll see: blocks, columns, leader_election, log, metadata, mutations,
-- nonincrement_block_numbers, part_moves_shard, pinned_part_uuids, quorum,
-- replicas, temp, zero_copy_s3, zero_copy_hdfs.

-- ---------- D. Insert deduplication (the free safety net) ----------
-- Re-running the EXACT SAME INSERT block is a no-op:
INSERT INTO lab.events
SELECT
    toDateTime('2026-01-01 00:00:00') + number,
    42, 1, 'US', '/home', 100
FROM numbers(10);
-- Run twice. Total rows added: 10, not 20.
-- Keeper hashes each block; identical blocks (same data, same order)
-- are recognized and skipped. Dedup window: insert_deduplication_window
-- entries per partition (default 100).
SELECT count() FROM lab.events WHERE site_id = 1 AND user_id = 42;

-- ---------- E. Force-fetch from another replica ----------
-- If a replica falls behind, you can force it to catch up:
SYSTEM SYNC REPLICA lab.events;
-- Blocks until this replica is caught up. Useful in CI/tests.

-- ---------- F. Operations cheat sheet ----------
-- Restart replication after manual intervention:
--   SYSTEM RESTART REPLICA lab.events;
-- Re-fetch a specific part from another replica:
--   ALTER TABLE lab.events FETCH PART 'all_1_1_0' FROM '/clickhouse/tables/01/lab/events/replicas/ch-2';
-- Detach replica from cluster (for retirement):
--   SYSTEM DROP REPLICA 'ch-2' FROM TABLE lab.events;

-- ---------- G. Cleanup ----------
-- DROP TABLE lab.events ON CLUSTER cluster_1s2r SYNC;
