-- Mimic prod inco_reader: SELECT on read.* only
CREATE ROLE IF NOT EXISTS inco_reader;
GRANT SELECT ON read.* TO inco_reader;

-- Read-only user that mirrors the prod replica_reader
CREATE USER IF NOT EXISTS replica_reader IDENTIFIED BY 'reader' DEFAULT ROLE inco_reader;
