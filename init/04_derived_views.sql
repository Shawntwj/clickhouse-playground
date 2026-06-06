-- ============================================================
-- Derived views — curated layers (au / nz / jp)
-- These read through read.* so they inherit FINAL transitively.
-- ============================================================

-- au: spot price summary over the hkpug5ii1l25n dispatch table
CREATE VIEW IF NOT EXISTS au.dispatch_summary AS
SELECT
    toStartOfHour(interval_utc)            AS hour_utc,
    region,
    fuel_type,
    avg(value_mw)                          AS avg_mw,
    max(value_mw)                          AS peak_mw,
    min(value_mw)                          AS min_mw,
    count()                                AS intervals
FROM read.hkpug5ii1l25n
GROUP BY hour_utc, region, fuel_type;

-- au: tag value pivot (last value per tag per day)
CREATE VIEW IF NOT EXISTS au.tag_daily_last AS
SELECT
    toDate(value_datetime_utc)  AS trading_date,
    tag,
    argMax(value_decimal, value_datetime_utc) AS last_value
FROM read.hkaggineq5gd7
GROUP BY trading_date, tag;

-- nz: active generation units with capacity
CREATE VIEW IF NOT EXISTS nz.active_units AS
SELECT *
FROM nz.generation_units
WHERE decommission_date IS NULL OR decommission_date > today();

-- dim: combined region dimension (AU + NZ)
CREATE VIEW IF NOT EXISTS dim.regions AS
SELECT
    'AU'       AS market,
    unit_id    AS id,
    region,
    fuel_type,
    capacity_mw
FROM nz.generation_units
WHERE decommission_date IS NULL OR decommission_date > today();
