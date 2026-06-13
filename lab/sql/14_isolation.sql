-- ============================================================
-- 14: ABUSE-PROOFING — isolation so heavy loads can't kill the box
-- ============================================================
-- The flip side of abusing the system: making sure abuse (yours or an
-- analyst's) degrades gracefully. This is what replaces autoscaling.

-- ---------- A. Memory ceilings per role ----------
CREATE USER IF NOT EXISTS analyst IDENTIFIED WITH plaintext_password BY 'analyst';
GRANT SELECT ON lab.* TO analyst;

CREATE SETTINGS PROFILE IF NOT EXISTS analyst_profile SETTINGS
    max_memory_usage = 1500000000,            -- 1.5GB per query: fail fast
    max_bytes_before_external_group_by = 750000000,  -- spill before failing
    max_execution_time = 30,                  -- no runaway scans
    max_threads = 2,                          -- leave cores for ingestion
    max_rows_to_read = 500000000
TO analyst;

-- Prove it (connect as analyst):
--   docker exec -it clickhouse clickhouse-client -u analyst --password analyst
-- then run a monster:
--   SELECT user_id, groupArray(url) FROM lab.events GROUP BY user_id;
-- It dies with MEMORY_LIMIT_EXCEEDED at 1.5GB — ingestion never notices.
-- Watch the Memory panel: a sharp peak that hits a ceiling and stops.

-- ---------- B. Quotas: rate limits in SQL ----------
CREATE QUOTA IF NOT EXISTS analyst_quota
    FOR INTERVAL 1 hour MAX queries = 500, read_rows = 10000000000
    TO analyst;
SELECT * FROM system.quotas_usage;

-- ---------- C. Priorities & concurrency ----------
-- Per-query priority (lower number = more important):
--   SELECT ... SETTINGS priority = 0;    -- dashboards
--   SELECT ... SETTINGS priority = 10;   -- batch/analyst
-- Server-side caps live in config: max_concurrent_queries,
-- background_pool_size (merge threads). On this lab box, fewer merge
-- threads = slower part cleanup = you can re-run exercise 11 and watch
-- the balance shift.

-- ---------- D. The kill switch ----------
SELECT query_id, elapsed, formatReadableSize(memory_usage) AS mem,
       substring(query, 1, 60) AS q
FROM system.processes ORDER BY elapsed DESC;

-- KILL QUERY WHERE query_id = '...';
-- KILL QUERY WHERE user = 'analyst';            -- nuke a whole role
-- KILL MUTATION WHERE table = 'firehose';        -- stop a runaway ALTER

-- ---------- E. The fixed-box doctrine (memorize) ----------
-- 1. Ingestion path gets reserved capacity (threads, memory) — it must
--    never compete with reads.
-- 2. Every human/service gets a profile with memory + time + thread caps.
-- 3. Dashboards read rollups behind the query cache.
-- 4. Raw data has a TTL. Disks fill on schedule, not by surprise.
-- With these four, a single well-sized server has a KNOWN worst case —
-- which is exactly the thing autoscaling bills you to avoid knowing.
