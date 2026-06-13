-- ============================================================
-- Exercise 3: Rewrite FINAL lookups using dictGet()
--
-- Pattern:
--   BEFORE: JOIN read.<small_table> t ON ...    (hits FINAL)
--   AFTER:  dictGet('db.dict_name', 'col', key) (hits memory)
--
-- Run the BEFORE query, note the ms in Grafana, then run AFTER.
-- ============================================================

-- ── Example A: Is a date a trading holiday? ─────────────────

-- BEFORE — joins through the FINAL layer
SELECT
    d.date_key,
    h.holiday_name,
    h.is_partial
FROM stg.date d
LEFT JOIN read.trading_holiday h
    ON d.date_key = h.date
   AND h.area     = 'NSW1'
   AND h.calendar = 'AEMO'
WHERE d.date_key >= today() - 30
ORDER BY d.date_key;

-- AFTER — dictGet on the in-memory dictionary
-- Note: COMPLEX_KEY_HASHED uses a tuple as the key
SELECT
    date_key,
    dictGet('tech.trading_holiday_dict', 'holiday_name', (date_key, 'NSW1', 'AEMO')) AS holiday_name,
    dictGetOrDefault('tech.trading_holiday_dict', 'is_partial', (date_key, 'NSW1', 'AEMO'), toUInt8(0)) AS is_partial,
    dictHas('tech.trading_holiday_dict', (date_key, 'NSW1', 'AEMO'))                 AS is_holiday
FROM stg.date
WHERE date_key >= today() - 30
ORDER BY date_key;

-- ── Example B: Enrich dispatch data with generation unit metadata ──

-- BEFORE — FINAL join on generation_units
SELECT
    d.interval_utc,
    d.duid,
    d.value_mw,
    u.fuel_type,
    u.capacity_mw,
    u.owner
FROM read.hkpug5ii1l25n d
LEFT JOIN read.generation_units u ON d.duid = u.unit_id
WHERE d.interval_utc >= now() - INTERVAL 1 DAY
LIMIT 1000;

-- AFTER — dictGet replaces the join entirely
SELECT
    interval_utc,
    duid,
    value_mw,
    dictGetOrDefault('nz.generation_units_dict', 'fuel_type',   duid, 'Unknown') AS fuel_type,
    dictGetOrDefault('nz.generation_units_dict', 'capacity_mw', duid, toFloat64(0)) AS capacity_mw,
    dictGetOrDefault('nz.generation_units_dict', 'owner',       duid, 'Unknown') AS owner
FROM read.hkpug5ii1l25n
WHERE interval_utc >= now() - INTERVAL 1 DAY
LIMIT 1000;

-- ── Example C: Replace a derived view with a dict-backed version ──

-- Drop the old FINAL-backed view and replace it
CREATE OR REPLACE VIEW au.dispatch_enriched AS
SELECT
    interval_utc,
    region,
    duid,
    value_mw,
    forecast_mw,
    -- fuel_type comes from the dictionary — no FINAL join
    dictGetOrDefault('nz.generation_units_dict', 'fuel_type',   duid, fuel_type)    AS fuel_type,
    dictGetOrDefault('nz.generation_units_dict', 'capacity_mw', duid, toFloat64(0)) AS capacity_mw,
    -- holiday flag comes from the dictionary — no FINAL join
    dictHas('tech.trading_holiday_dict', (toDate(interval_utc), region, 'AEMO'))    AS is_holiday
FROM read.hkpug5ii1l25n;

-- Test the new view
SELECT * FROM au.dispatch_enriched LIMIT 10;
