-- Roles require admin privileges — run manually after startup:
-- docker exec -it clickhouse clickhouse-client --user default
-- CREATE ROLE IF NOT EXISTS inco_reader;
-- GRANT SELECT ON read.* TO inco_reader;
-- CREATE USER IF NOT EXISTS replica_reader IDENTIFIED BY 'reader' DEFAULT ROLE inco_reader;
SELECT 1; -- placeholder so the file doesn't fail
