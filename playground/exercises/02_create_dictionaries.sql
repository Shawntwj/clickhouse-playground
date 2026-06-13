-- ============================================================
-- Exercise 2: Create dictionaries for the §4a candidate tables
--
-- These are the small reference tables currently served through
-- read.* FINAL. Dictionaries load into memory and serve lookups
-- without touching MergeTree at all.
--
-- After running each CREATE DICTIONARY, check Grafana:
--   "Dictionary Memory" panel should show the new dict loaded.
-- ============================================================

-- ── tech.trading_holiday (1,922 rows) ───────────────────────
-- Composite key: date + area + calendar
CREATE DICTIONARY IF NOT EXISTS tech.trading_holiday_dict (
    date            Date,
    area            String,
    calendar        String,
    holiday_name    String,
    is_partial      UInt8
)
PRIMARY KEY date, area, calendar
SOURCE(CLICKHOUSE(
    TABLE   'trading_holiday'
    DB      'tech'
    USER    'admin'
    PASSWORD 'admin'
))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 600);   -- refresh every 5-10 min

-- ── utl.kafka_crossdb_connectors (27 rows) ──────────────────
CREATE DICTIONARY IF NOT EXISTS utl.kafka_connectors_dict (
    table_schema    String,
    table_name      String,
    kafka_topic     String
)
PRIMARY KEY table_schema, table_name
SOURCE(CLICKHOUSE(
    TABLE   'kafka_crossdb_connectors'
    DB      'utl'
    USER    'admin'
    PASSWORD 'admin'
))
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 600 MAX 3600);  -- rarely changes

-- ── nz.generation_units (111 rows) ──────────────────────────
-- Simple string key lookup (unit_id → attributes)
CREATE DICTIONARY IF NOT EXISTS nz.generation_units_dict (
    unit_id             String,
    unit_name           String,
    fuel_type           String,
    capacity_mw         Float64,
    owner               String,
    region              String
)
PRIMARY KEY unit_id
SOURCE(CLICKHOUSE(
    TABLE   'generation_units'
    DB      'nz'
    USER    'admin'
    PASSWORD 'admin'
))
LAYOUT(HASHED())             -- single-key → flat HASHED is fastest
LIFETIME(MIN 300 MAX 900);

-- ── Verify dictionaries loaded ───────────────────────────────
SELECT
    database,
    name,
    status,
    element_count,
    bytes_allocated,
    last_successful_update_time
FROM system.dictionaries
ORDER BY database, name;
