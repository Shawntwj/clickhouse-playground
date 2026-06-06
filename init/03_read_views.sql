-- ============================================================
-- read.* views — SELECT * FROM datacapture.<topic> FINAL
-- Mirrors the 982 FINAL-layer views from production.
-- Only the 3 seeded datacapture tables are wired up here;
-- add more as you expand datacapture.
-- ============================================================

CREATE VIEW IF NOT EXISTS read.hkpug5ii1l25n AS
    SELECT * FROM datacapture.hkpug5ii1l25n FINAL;

CREATE VIEW IF NOT EXISTS read.hkaggineq5gd7 AS
    SELECT * FROM datacapture.hkaggineq5gd7 FINAL;

CREATE VIEW IF NOT EXISTS read.fvow3t4chjeqj AS
    SELECT * FROM datacapture.fvow3t4chjeqj FINAL;
