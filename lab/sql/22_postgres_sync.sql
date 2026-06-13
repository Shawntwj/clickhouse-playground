-- ============================================================
-- 22: POSTGRES SYNC — OLTP in, analytics out
-- ============================================================
-- Requires: make up-integrations (Postgres seeded with customers + orders).
-- This is the most common real-world integration: app data lives in
-- Postgres, analytics live in ClickHouse. Four escalating patterns:

-- ---------- Pattern 1: just query it live (no sync at all) ----------
SELECT plan, count()
FROM postgresql('postgres:5432', 'app', 'customers', 'postgres', 'lab')
GROUP BY plan;
-- Every query hits Postgres. Fine for small tables and exploration;
-- terrible as a JOIN target in hot queries. So:

-- ---------- Pattern 2: dictionary on Postgres (live dims, cached in RAM) ----------
CREATE DICTIONARY lab.customers_dict
(
    customer_id UInt32,
    name        String,
    plan        String,
    country     String
)
PRIMARY KEY customer_id
SOURCE(POSTGRESQL(HOST 'postgres' PORT 5432 DB 'app' TABLE 'customers'
                  USER 'postgres' PASSWORD 'lab'))
LAYOUT(HASHED())
LIFETIME(MIN 60 MAX 120);
-- Now Postgres rows are an O(1) in-RAM lookup, auto-refreshed every minute:
SELECT dictGet('lab.customers_dict', 'plan', toUInt64(42)) AS plan_of_customer_42;
-- Update the row in Postgres, wait for LIFETIME (or SYSTEM RELOAD
-- DICTIONARY), query again. You just built a near-real-time dimension
-- sync with zero pipeline code.
--   docker exec pg psql -U postgres app -c \
--     "UPDATE customers SET plan='enterprise' WHERE customer_id=42"

-- ---------- Pattern 3: refreshable MV (scheduled full-copy sync) ----------
SET allow_experimental_refreshable_materialized_view = 1;  -- needed on 24.8

CREATE MATERIALIZED VIEW lab.orders_sync
REFRESH EVERY 1 MINUTE
ENGINE = MergeTree ORDER BY (customer_id, created_at)
AS SELECT
    order_id, customer_id,
    toDecimal64(amount, 2) AS amount,
    created_at
FROM postgresql('postgres:5432', 'app', 'orders', 'postgres', 'lab');

-- Watch it run:
SELECT view, status, last_success_time, next_refresh_time
FROM system.view_refreshes;

-- Now do analytics Postgres could never do cheaply, enriched via the dict:
SELECT
    dictGet('lab.customers_dict', 'plan', toUInt64(customer_id)) AS plan,
    count() AS orders,
    sum(amount) AS revenue
FROM lab.orders_sync
GROUP BY plan;
-- This is cron-free ELT in two CREATE statements. Right answer for tables
-- up to a few tens of millions of rows where minute-level lag is fine.

-- ---------- Pattern 4: true CDC (when you outgrow pattern 3) ----------
-- Row-level change streaming, big tables, second-level lag:
--   Postgres WAL ─► Debezium ─► Kafka ─► Kafka engine + MV (exercise 21!)
--                                        into ReplacingMergeTree(version)
-- Deletes/updates become versioned rows; reads dedup with the FINAL-dodging
-- tricks from exercise 13. (MaterializedPostgreSQL engine does this
-- natively but is experimental — know it exists, don't bet prod on it.)
-- Notice: CDC is just exercises 21 + 13 composed. You already have every piece.

-- ---------- The decision ladder ----------
-- live query  -> exploration, tiny tables
-- dictionary  -> dimensions you enrich with        (minutes of lag, RAM-sized)
-- refreshable -> full small/medium table sync      (minutes of lag)
-- CDC         -> big/hot tables, deletes, seconds of lag
