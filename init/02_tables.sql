-- ============================================================
-- Reference / config tables (§4a from runbook — OSS engines)
-- SharedReplacingMergeTree → ReplacingMergeTree
-- SharedMergeTree          → MergeTree
-- ============================================================

-- au schema
CREATE TABLE IF NOT EXISTS au.job_errors (
    occurred_at     DateTime64(3) NOT NULL,
    job_name        String,
    error_message   String,
    error_code      Int32,
    retry_count     UInt8
) ENGINE = MergeTree()
ORDER BY occurred_at;

CREATE TABLE IF NOT EXISTS au.ppa_details (
    duid                    String NOT NULL,
    start_datetime_utc      DateTime64(3) NOT NULL,
    end_datetime_utc        DateTime64(3),
    counterparty_name       String,
    contract_volume_mw      Decimal(18, 6),
    strike_price            Decimal(18, 6),
    floor_price             Decimal(18, 6),
    cap_price               Decimal(18, 6),
    settlement_type         String,
    region                  String,
    is_active               Bool
) ENGINE = MergeTree()
ORDER BY (duid, start_datetime_utc);

CREATE TABLE IF NOT EXISTS au.bess_mtm (
    mtmdate     Date NOT NULL,
    bookid      String NOT NULL,
    duid        String NOT NULL,
    mtm_value   Decimal(18, 6),
    delta       Decimal(18, 6),
    gamma       Decimal(18, 6),
    vega        Decimal(18, 6),
    theta       Decimal(18, 6),
    version     UInt8
) ENGINE = ReplacingMergeTree(version)
ORDER BY (mtmdate, bookid, duid);

CREATE TABLE IF NOT EXISTS au.bess_position (
    date        Date NOT NULL,
    duid        String NOT NULL,
    load_date   DateTime64(3) NOT NULL,
    position_mw Decimal(18, 6),
    pnl         Decimal(18, 6),
    region      String,
    version     UInt8
) ENGINE = ReplacingMergeTree(version)
ORDER BY (date, duid, load_date);

CREATE TABLE IF NOT EXISTS au.ppa_position (
    date        Date NOT NULL,
    duid        String NOT NULL,
    load_date   DateTime64(3) NOT NULL,
    position_mw Decimal(18, 6),
    pnl         Decimal(18, 6),
    region      String,
    fuel_type   String,
    version     UInt8
) ENGINE = ReplacingMergeTree(version)
ORDER BY (date, duid, load_date);

CREATE TABLE IF NOT EXISTS au.ppa_production (
    duid                String NOT NULL,
    value_datetime_utc  DateTime64(3) NOT NULL,
    production_mwh      Decimal(18, 6),
    availability_mw     Decimal(18, 6),
    region              String,
    fuel_type           String,
    settlement_type     String,
    forecast_mwh        Decimal(18, 6),
    variance_mwh        Decimal(18, 6),
    version             UInt8
) ENGINE = ReplacingMergeTree(version)
ORDER BY (duid, value_datetime_utc);

-- jp schema
CREATE TABLE IF NOT EXISTS jp.eex_futures_mapping (
    id              Int32 NOT NULL,
    product_code    String,
    maturity_date   Date,
    contract_type   String,
    multiplier      Decimal(18, 6)
) ENGINE = MergeTree()
ORDER BY id;

CREATE TABLE IF NOT EXISTS jp.shinanen_balancing_mapping (
    balancing_group     String NOT NULL,
    plant_id            String NOT NULL,
    grid_code           String NOT NULL,
    capacity_mw         Decimal(18, 6),
    version             UInt8
) ENGINE = ReplacingMergeTree(version)
ORDER BY (balancing_group, plant_id, grid_code);

-- mdm schema
CREATE TABLE IF NOT EXISTS mdm.counterparty (
    counterparty_name   String NOT NULL,
    counterparty_id     Int32,
    country             String,
    region              String,
    sector              String,
    credit_rating       String,
    is_active           Bool,
    onboarded_date      Date,
    contact_email       String,
    legal_entity        String,
    version             UInt8
) ENGINE = ReplacingMergeTree(version)
ORDER BY counterparty_name;

-- nz schema
CREATE TABLE IF NOT EXISTS nz.generation_units (
    unit_id             String NOT NULL,
    unit_name           String,
    fuel_type           String,
    capacity_mw         Decimal(18, 3),
    owner               String,
    region              String,
    commissioning_date  Date,
    decommission_date   Nullable(Date),
    latitude            Float64,
    longitude           Float64
) ENGINE = MergeTree()
ORDER BY tuple();

CREATE TABLE IF NOT EXISTS nz.holidays (
    holiday_date        Date NOT NULL,
    holiday_name        String,
    region              String,
    is_national         Bool,
    day_of_week         String,
    trading_period      Int32,
    is_half_day         Bool,
    jurisdiction        String,
    calendar_type       String,
    observed_date       Nullable(Date),
    substitute_day      Bool
    -- (22 more columns exist in prod — truncated for brevity)
) ENGINE = MergeTree()
ORDER BY tuple();

CREATE TABLE IF NOT EXISTS nz.trading_periods (
    trading_period_id   Int32 NOT NULL,
    period_start_utc    DateTime64(3),
    period_end_utc      DateTime64(3),
    trading_date        Date,
    period_number       Int32,
    region              String,
    is_dst_transition   Bool,
    duration_minutes    Int32,
    market_type         String,
    settlement_type     String
    -- (12 more columns exist in prod — truncated for brevity)
) ENGINE = MergeTree()
ORDER BY tuple();

-- stg schema
CREATE TABLE IF NOT EXISTS stg.date (
    date_key    Date NOT NULL,
    date_label  String
) ENGINE = MergeTree()
ORDER BY tuple();

-- tech schema
CREATE TABLE IF NOT EXISTS tech.trading_holiday (
    date        Date NOT NULL,
    area        String NOT NULL,
    calendar    String NOT NULL,
    holiday_name    String,
    is_partial  Bool
) ENGINE = MergeTree()
ORDER BY (date, area, calendar);

-- utl schema
CREATE TABLE IF NOT EXISTS utl.kafka_crossdb_connectors (
    table_schema    String NOT NULL,
    table_name      String NOT NULL,
    kafka_topic     String
) ENGINE = MergeTree()
ORDER BY (table_schema, table_name);

-- ============================================================
-- datacapture — 3 representative raw-zone tables
-- (full 982 tables are in recreate_ddl.sql from production)
-- ============================================================

-- High-cardinality time-series (energy dispatch, ~4.8B rows in prod)
CREATE TABLE IF NOT EXISTS datacapture.hkpug5ii1l25n (
    model_run_datetime_utc  DateTime64(3) NOT NULL,
    id                      Int32 NOT NULL,
    interval_utc            DateTime64(3) NOT NULL,
    duid                    String,
    region                  String,
    fuel_type               String,
    value_mw                Decimal(18, 6),
    forecast_mw             Decimal(18, 6),
    run_type                String,
    version                 UInt8
) ENGINE = ReplacingMergeTree(version)
ORDER BY (model_run_datetime_utc, id, interval_utc, duid, region, fuel_type);

-- Tag/value time-series (narrow schema, ~895M rows in prod)
CREATE TABLE IF NOT EXISTS datacapture.hkaggineq5gd7 (
    issue_datetime_utc      DateTime64(3) NOT NULL,
    id                      Int32 NOT NULL,
    tag                     String NOT NULL,
    value_datetime_utc      DateTime64(3) NOT NULL,
    value_decimal           Decimal(18, 6),
    value_string            Nullable(String),
    last_modified_utc       DateTime64(3),
    version                 UInt8
) ENGINE = ReplacingMergeTree(version)
ORDER BY (issue_datetime_utc, id, tag, value_datetime_utc);

-- Wide schema NEMDE solution (~72M rows, 132 cols in prod)
CREATE TABLE IF NOT EXISTS datacapture.fvow3t4chjeqj (
    last_changed_datetime_utc   DateTime64(3) NOT NULL,
    solution_datetime_utc       DateTime64(3) NOT NULL,
    region_id                   String NOT NULL,
    totaldemand                 Decimal(18, 6),
    availablegeneration         Decimal(18, 6),
    availableload               Decimal(18, 6),
    clearedgeneration           Decimal(18, 6),
    rrp                         Decimal(18, 6),
    raise6secrrp                Decimal(18, 6),
    raise60secrrp               Decimal(18, 6),
    raise5minrrp                Decimal(18, 6),
    raiseregrrp                 Decimal(18, 6),
    lower6secrrp                Decimal(18, 6),
    lower60secrrp               Decimal(18, 6),
    lower5minrrp                Decimal(18, 6),
    lowerregrrp                 Decimal(18, 6),
    totalintermittentgeneration Decimal(18, 6),
    demand_and_nonschedgen      Decimal(18, 6),
    dispatchableload            Decimal(18, 6),
    -- (113 more cols in prod — add as needed)
    version                     UInt8
) ENGINE = ReplacingMergeTree(version)
ORDER BY (last_changed_datetime_utc, solution_datetime_utc, region_id);
