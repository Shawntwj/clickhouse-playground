-- ============================================================
-- 40: CLUSTER SETUP — ON CLUSTER, Keeper, the wiring
-- ============================================================
-- Prereq: `make up-cluster` (Keeper + ch-1 + ch-2)
-- Run these on ch-1 (or anywhere) — ON CLUSTER fans the DDL out.

-- ---------- A. See the clusters and the Keeper ----------
SELECT cluster, shard_num, replica_num, host_name, port, is_local
FROM system.clusters
WHERE cluster LIKE 'cluster_%'
ORDER BY cluster, shard_num, replica_num;
-- Two clusters defined in cluster/config/common/clusters.xml:
--   cluster_1s2r  1 shard  × 2 replicas    (ch-1, ch-2)  → ReplicatedMergeTree (ex. 41)
--   cluster_2s1r  2 shards × 1 replica     (ch-1 | ch-2) → Distributed/sharding (ex. 42)

-- Keeper is the coordination service. Reach it through the virtual system table:
SELECT name, value FROM system.zookeeper WHERE path = '/';
-- You should see at least 'clickhouse' and 'keeper'. If this errors, Keeper
-- isn't reachable from this node — check `docker logs ch-keeper`.

-- ---------- B. ON CLUSTER DDL ----------
-- Without ON CLUSTER, DDL runs on the node you're connected to ONLY.
-- ON CLUSTER pushes the same DDL to every node in the named cluster,
-- via a DDL queue persisted in Keeper.
CREATE DATABASE IF NOT EXISTS lab ON CLUSTER cluster_1s2r;

-- Inspect the DDL queue (every ON CLUSTER statement goes through here):
SELECT host_name, query, query_create_time, exception
FROM system.distributed_ddl_queue
ORDER BY query_create_time DESC
LIMIT 5;
-- A healthy entry has exception = '' and a finished status on every host.

-- ---------- C. Per-node macros ----------
-- Each node's config/macros.xml exposes {shard} and {replica}.
-- These are the substitution variables used in ReplicatedMergeTree paths.
SELECT macro, substitution FROM system.macros;
-- On ch-1: {shard}=01, {replica}=ch-1
-- On ch-2: {shard}=01, {replica}=ch-2
-- Both nodes have the SAME shard (01) — they're replicas of the same shard
-- in cluster_1s2r. For cluster_2s1r we use literal shard numbers in DDL.

-- ---------- D. Verify both nodes are healthy ----------
SELECT _shard_num, hostName(), version()
FROM clusterAllReplicas('cluster_1s2r', system.one);
-- Should return TWO rows: ch-1 and ch-2. If one is missing, that node is down
-- or unreachable. clusterAllReplicas() is the cluster-wide query function —
-- exercise 44 covers it in depth.

-- ---------- E. The Keeper paths ClickHouse uses ----------
SELECT name, ctime, numChildren
FROM system.zookeeper WHERE path = '/clickhouse';
-- After exercise 41 you'll see /clickhouse/tables here — that's where
-- ReplicatedMergeTree stores its coordination state.

-- ---------- F. Cleanup helpers (run BEFORE moving on) ----------
-- DROP DATABASE lab ON CLUSTER cluster_1s2r SYNC;
-- SYNC = wait for the drop to complete on every node before returning.
