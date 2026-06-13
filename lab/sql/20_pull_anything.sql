-- ============================================================
-- 20: PULL ANYTHING — "every external system is just a table"
-- ============================================================
-- ClickHouse's integration superpower is table FUNCTIONS: they make a URL,
-- a file, an S3 bucket, or another database queryable as if it were local.
-- Master this and "integration" stops being a project — it's a FROM clause.

-- ---------- A. A remote file on the internet is a table ----------
-- (Runs on YOUR machine where the container has internet.)
SELECT town, district, count() AS sales, round(avg(price)) AS avg_price
FROM url(
    'https://datasets-documentation.s3.eu-west-3.amazonaws.com/uk-house-prices/parquet/house_prices_2022.parquet',
    Parquet)
GROUP BY town, district
ORDER BY sales DESC
LIMIT 10;
-- No ingestion happened. ClickHouse streamed a remote Parquet file,
-- pushed the aggregation down, and answered. Schema was inferred.

-- Inspect what it inferred:
DESCRIBE url('https://datasets-documentation.s3.eu-west-3.amazonaws.com/uk-house-prices/parquet/house_prices_2022.parquet', Parquet);

-- ---------- B. Ingestion = INSERT SELECT from the function ----------
CREATE TABLE lab.house_prices
ENGINE = MergeTree ORDER BY (town, date)
EMPTY AS SELECT * FROM url('https://datasets-documentation.s3.eu-west-3.amazonaws.com/uk-house-prices/parquet/house_prices_2022.parquet', Parquet);

INSERT INTO lab.house_prices
SELECT * FROM url('https://datasets-documentation.s3.eu-west-3.amazonaws.com/uk-house-prices/parquet/house_prices_2022.parquet', Parquet);
-- That two-statement pattern (EMPTY AS SELECT to clone the schema, then
-- INSERT SELECT) is the universal bulk-import recipe.

-- ---------- C. The full function family (same pattern, every system) ----------
--   s3('s3://bucket/path/*.parquet', ...)        object storage, glob patterns
--   file('/var/lib/clickhouse/user_files/x.csv') local files
--   postgresql('host:5432','db','table','u','p') live Postgres (exercise 22)
--   mysql(...), mongodb(...), redis(...)         other databases
--   remote('other-ch:9000', db.table)            another ClickHouse
--   url('https://api...', JSONEachRow)           any HTTP API that emits rows
-- Each also exists as a table ENGINE (persistent alias instead of inline).

-- ---------- D. Export is the same thing backwards ----------
SELECT * FROM lab.events_1m LIMIT 100
INTO OUTFILE '/var/lib/clickhouse/user_files/rollup.parquet' FORMAT Parquet;
-- ClickHouse speaks ~70 formats. INSERT INTO FUNCTION s3(...) writes
-- straight to a bucket — CH as the ETL engine, not just the destination.

-- ---------- E. clickhouse-local: the engine without the server ----------
-- In your shell — full SQL on local files, zero setup:
--   docker exec ch clickhouse-local -q "
--     SELECT count() FROM file('/var/lib/clickhouse/user_files/rollup.parquet', Parquet)"
-- This replaces half of pandas/awk for data wrangling. Pipe anything in,
-- SQL it, pipe anything out. The most underrated integration tool CH ships.
