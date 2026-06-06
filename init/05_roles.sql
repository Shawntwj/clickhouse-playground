-- Mimic prod inco_reader: SELECT on read.* only
-- Note: role/user DDL may need to run as default admin user
CREATE ROLE IF NOT EXISTS inco_reader;
GRANT SELECT ON read.* TO inco_reader;
