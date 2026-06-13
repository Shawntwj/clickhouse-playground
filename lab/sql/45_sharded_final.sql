-- ============================================================
-- 45: SHARDED ReplacingMergeTree — FINAL is BROKEN. Use argMax.
-- ============================================================
-- Prereq: exercise 42 (sharding) — and read lab/sql/13_read_warfare.sql
-- for the single-node FINAL-dodging tricks. This exercise extends them
-- to the cluster case, where FINAL is even more wrong.

-- ---------- The trap ----------
-- ReplicatedMergeTree dedups WITHIN a single replica's parts.
-- It does NOT dedup ACROSS shards. If a duplicate row lands on shard A
-- on Monday and the corrected row lands on shard B on Tuesday, FINAL
-- on the Distributed table happily returns BOTH — they're on different
-- physical merge trees and the engine has no way to combine them.
--
-- This is a silent correctness bug. Production tables built this way
-- ship wrong numbers to dashboards and nobody notices until reconciliation.

-- ---------- A. Set up a sharded ReplacingMergeTree ----------
CREATE TABLE lab.user_state_local ON CLUSTER cluster_2s1r
(
    user_id    UInt32,
    plan       LowCardinality(String),
    updated_at DateTime,
    version    UInt64
)
ENGINE = ReplacingMergeTree(version)
ORDER BY user_id;

CREATE TABLE lab.user_state_dist ON CLUSTER cluster_2s1r AS lab.user_state_local
ENGINE = Distributed('cluster_2s1r', 'lab', 'user_state_local', cityHash64(user_id));

-- ---------- B. Reproduce the bug on purpose ----------
-- Put an old version of user 42 on ch-1, then a newer version of the SAME
-- user on ch-2. With cityHash64-based sharding, user 42 normally hashes
-- to one shard — so we'll insert directly into the LOCAL tables to force
-- the bug for teaching.

-- On ch-1 (make sql-1):
--   INSERT INTO lab.user_state_local VALUES (42, 'free', now() - 100, 1);
-- On ch-2 (make sql-2):
--   INSERT INTO lab.user_state_local VALUES (42, 'pro',  now(),       2);

-- ---------- C. The naive FINAL is WRONG ----------
SELECT user_id, plan, version
FROM lab.user_state_dist FINAL
WHERE user_id = 42;
-- Returns BOTH rows. FINAL on Distributed only applies FINAL to each
-- shard's slice — and each shard has exactly one row, so "nothing to dedup".
-- The cross-shard duplicate survives.

-- ---------- D. The correct pattern: argMax ----------
SELECT user_id, argMax(plan, version) AS plan, max(version) AS version
FROM lab.user_state_dist
WHERE user_id = 42
GROUP BY user_id;
-- argMax dedups across the WHOLE result set (post-merge by the initiator).
-- Always correct, works on Replicated AND Distributed, no FINAL needed.

-- ---------- E. The full "current state of every user" query ----------
SELECT plan, count() AS users
FROM (
    SELECT user_id, argMax(plan, version) AS plan
    FROM lab.user_state_dist
    GROUP BY user_id
)
GROUP BY plan;
-- This is the production pattern. It's faster than FINAL on a single node,
-- and on a cluster it's the only correct approach.

-- ---------- F. The MV pre-dedup variant (best for hot dashboards) ----------
-- Maintain a "current state" target table with an AggregatingMergeTree
-- that argMax-merges on insert. Dashboard reads the target — no dedup logic.
CREATE TABLE lab.user_state_current_local ON CLUSTER cluster_2s1r
(
    user_id UInt32,
    plan    AggregateFunction(argMax, LowCardinality(String), UInt64),
    version SimpleAggregateFunction(max, UInt64)
)
ENGINE = AggregatingMergeTree
ORDER BY user_id;

CREATE MATERIALIZED VIEW lab.user_state_current_mv ON CLUSTER cluster_2s1r
TO lab.user_state_current_local AS
SELECT
    user_id,
    argMaxState(plan, version) AS plan,
    max(version)               AS version
FROM lab.user_state_local
GROUP BY user_id;

-- Dashboard query (no FINAL, no argMax in the user-facing SQL):
CREATE TABLE lab.user_state_current_dist ON CLUSTER cluster_2s1r
AS lab.user_state_current_local
ENGINE = Distributed('cluster_2s1r', 'lab', 'user_state_current_local', user_id);

SELECT user_id, argMaxMerge(plan), max(version)
FROM lab.user_state_current_dist
WHERE user_id = 42
GROUP BY user_id;

-- ---------- G. The pattern hierarchy ----------
-- Single node:
--   1. argMax in the read query              — fastest, always correct
--   2. SELECT FINAL with the tuned settings  — correct, slower (see ex. 13)
--   3. Pre-deduped MV target                  — fastest for dashboards
--
-- Sharded cluster:
--   1. argMax — STILL fastest, STILL always correct
--   2. SELECT FINAL — SILENTLY WRONG across shards, do not use
--   3. Pre-deduped MV with AggregatingMergeTree — best for high-QPS reads
--
-- The exercises in this lab (single node) sometimes show FINAL as the
-- "correct, slower" baseline. In a cluster, treat FINAL as red.

-- ---------- H. Cleanup ----------
-- DROP TABLE lab.user_state_dist           ON CLUSTER cluster_2s1r SYNC;
-- DROP TABLE lab.user_state_local          ON CLUSTER cluster_2s1r SYNC;
-- DROP TABLE lab.user_state_current_dist   ON CLUSTER cluster_2s1r SYNC;
-- DROP TABLE lab.user_state_current_mv     ON CLUSTER cluster_2s1r SYNC;
-- DROP TABLE lab.user_state_current_local  ON CLUSTER cluster_2s1r SYNC;
