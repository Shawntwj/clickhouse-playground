-- ============================================================
-- 42: DISTRIBUTED + SHARDING — one logical table over N shards
-- ============================================================
-- Prereq: exercise 40 (cluster up)
--
-- The Distributed engine is a ROUTER, not a storage engine. It points at
-- a per-shard storage table and an optional sharding key. Writes route
-- based on the key; reads fan out to every shard and merge results.

-- ---------- A. Create the per-shard storage table ----------
-- Same MergeTree on each shard (no replication here — cluster_2s1r has 1 replica/shard):
CREATE TABLE lab.events_local ON CLUSTER cluster_2s1r
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

-- ---------- B. Create the Distributed table on top ----------
-- Sharding key: cityHash64(user_id). Rows route to shard based on hash % shard_count.
CREATE TABLE lab.events_dist ON CLUSTER cluster_2s1r AS lab.events_local
ENGINE = Distributed(
    'cluster_2s1r',     -- cluster name
    'lab',              -- target DB
    'events_local',     -- target table on each shard
    cityHash64(user_id) -- sharding key (optional; without it, writes go round-robin or to local)
);

-- ---------- C. Insert through the Distributed table ----------
INSERT INTO lab.events_dist
SELECT
    now() - toIntervalSecond(rand() % 3600),
    rand() % 1000000, rand() % 500,
    ['US','DE','IN'][1 + rand() % 3],
    ['/home','/cart'][1 + rand() % 2],
    rand() % 5000
FROM numbers(1000000);

-- Verify the data ACTUALLY landed on different shards:
SELECT
    hostName() AS host,
    count()    AS rows_on_this_node
FROM clusterAllReplicas('cluster_2s1r', lab.events_local)
GROUP BY host;
-- Expect roughly 500k on ch-1 and 500k on ch-2. Hash distribution is
-- random but uniform for a uniformly distributed key.

-- ---------- D. Reads fan out automatically ----------
SELECT count(), uniq(user_id) FROM lab.events_dist;
-- Each shard runs the count() locally, then the initiator merges the
-- partials. uniq() ships HLL state, not raw values. Aggregations were
-- designed for this — most are mergeable.

-- ---------- E. Cross-shard JOIN gotcha (and the fix) ----------
-- Naive JOIN on Distributed sends the RIGHT side to each shard separately,
-- which can be small joins repeating work or, worse, missing rows that
-- live on a different shard. Three options:
--
-- 1. GLOBAL JOIN: initiator collects the right side, broadcasts to all shards
SELECT count() FROM lab.events_dist e
GLOBAL ANY INNER JOIN (SELECT 1 AS site_id, 'tier_a' AS tier) s
USING site_id;
-- Good for small right sides.

-- 2. Dictionary: load the dim into RAM on every node, dictGet locally.
--    This is THE pattern for cluster JOINs — exercise 04 was preparation.

-- 3. distributed_product_mode setting:
--    'deny'  (default) → throws if your JOIN risks the wrong answer
--    'local' → run on each shard's local table (assumes you've co-located)
--    'global' → behaves like GLOBAL JOIN automatically

-- ---------- F. Routing settings worth knowing ----------
-- insert_distributed_sync = 1     wait for ack from each shard (slower, safer)
-- prefer_localhost_replica = 1    cut a network hop when the initiator is also a replica
-- max_parallel_replicas = N       split a single query across replicas of the same shard

-- ---------- G. Inspect what landed where ----------
SELECT shard_num, count() AS rows
FROM (
    SELECT _shard_num AS shard_num
    FROM clusterAllReplicas('cluster_2s1r', lab.events_local)
)
GROUP BY shard_num ORDER BY shard_num;
-- _shard_num is a virtual column on clusterAllReplicas() / Distributed reads.
-- Use it to verify sharding distribution and find skew.

-- ---------- H. Cleanup ----------
-- DROP TABLE lab.events_dist  ON CLUSTER cluster_2s1r SYNC;
-- DROP TABLE lab.events_local ON CLUSTER cluster_2s1r SYNC;
