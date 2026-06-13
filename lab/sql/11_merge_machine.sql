-- ============================================================
-- 11: THE MERGE MACHINE — break it on purpose, then drive it manually
-- ============================================================
-- Merges are the heartbeat of MergeTree. Experts don't fear "Too many
-- parts" — they know exactly which knobs produce and relieve it.

-- The guardrails (per-table MergeTree settings):
SELECT name, value, description
FROM system.merge_tree_settings
WHERE name IN ('parts_to_delay_insert', 'parts_to_throw_insert',
               'max_bytes_to_merge_at_max_space_in_pool',
               'min_bytes_for_wide_part', 'old_parts_lifetime');
-- parts_to_delay_insert: CH starts SLEEPING your inserts (backpressure)
-- parts_to_throw_insert: the famous exception
-- max_bytes_to_merge_...: parts bigger than this stop being merged (~150GB)

-- ---------- EXPERIMENT: induce the disease, watch the cure ----------
-- 1. Freeze merges:
SYSTEM STOP MERGES lab.firehose;

-- 2. In your shell:  make storm-sync
--    Grafana: "Active parts" climbs in a straight line — nothing fights back.
--    Around parts_to_delay_insert you'll see inserts get slower (backpressure),
--    then the throw threshold kills them.

-- 3. Release the merges and watch the avalanche:
SYSTEM START MERGES lab.firehose;

-- Live view of the engine catching up:
SELECT table, elapsed, progress, num_parts,
       formatReadableSize(total_size_bytes_compressed) AS merging
FROM system.merges;

-- Post-mortem — every part's birth and death is logged:
SELECT event_type, count(), avg(duration_ms) AS avg_ms
FROM system.part_log
WHERE table = 'firehose' AND event_date = today()
GROUP BY event_type;
-- NewPart count vs MergeParts count = your insert:merge ratio. Healthy
-- systems merge in big steps: few merges, each combining many parts.

-- ---------- Merge levels: the LSM-like shape ----------
SELECT level, count() AS parts, sum(rows) AS rows
FROM system.parts
WHERE table = 'events' AND active
GROUP BY level ORDER BY level;
-- A settled table converges to a handful of high-level parts. Many level-0
-- parts hours after inserting = merges starved (CPU? disk? too many tables?).

-- ---------- Manual control ----------
OPTIMIZE TABLE lab.firehose FINAL;        -- force merge to ~1 part/partition.
-- Expert use: nightly OPTIMIZE on yesterday's partition only:
-- OPTIMIZE TABLE lab.firehose PARTITION '202606' FINAL;
-- Abuse warning: OPTIMIZE FINAL on a huge hot table rewrites everything —
-- it's a sledgehammer, schedule it, don't reflex it.

-- Partition surgery — instant, metadata-only operations experts abuse daily:
-- ALTER TABLE lab.firehose DROP PARTITION '202605';        -- instant delete
-- ALTER TABLE lab.firehose DETACH PARTITION '202605';      -- hide, keep on disk
-- ALTER TABLE lab.firehose ATTACH PARTITION '202605';      -- bring it back
-- ALTER TABLE t2 ATTACH PARTITION '202606' FROM lab.firehose;  -- zero-copy move
-- This is why PARTITION BY exists: lifecycle ops at file-system speed,
-- vs DELETE FROM which rewrites parts (mutations — see below).

-- ---------- Mutations: the slow path you should distrust ----------
ALTER TABLE lab.firehose DELETE WHERE site_id = 13;
SELECT * FROM system.mutations WHERE table = 'firehose' FORMAT Vertical;
-- A mutation rewrites every affected part in the background. On big tables
-- this can run for hours. Experts design so they never need row mutations:
-- partition drops, TTLs, ReplacingMergeTree versions (exercise 13).
