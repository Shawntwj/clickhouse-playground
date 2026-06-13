-- ============================================================
-- Synthetic data seeding — run against localhost:8123
-- Usage:  clickhouse-client -h localhost -u admin --password admin < scripts/seed_data.sql
-- ============================================================

-- Reference tables (small, exact-ish row counts from §4b)

INSERT INTO utl.kafka_crossdb_connectors (table_schema, table_name, kafka_topic)
SELECT
    arrayElement(['datacapture', 'read'], (rand() % 2) + 1)   AS table_schema,
    concat('topic_', toString(number))                          AS table_name,
    concat('kafka.topic.', toString(number))                    AS kafka_topic
FROM numbers(27);

INSERT INTO tech.trading_holiday (date, area, calendar, holiday_name, is_partial)
SELECT
    today() - (number % 1095)                                                AS date,
    arrayElement(['NSW1','QLD1','VIC1','SA1','TAS1'], (rand() % 5) + 1)     AS area,
    arrayElement(['AEMO','ASX','NZX'], (rand() % 3) + 1)                    AS calendar,
    concat('Holiday_', toString(number % 30))                                AS holiday_name,
    toBool(rand() % 2)                                                       AS is_partial
FROM numbers(1922);

INSERT INTO stg.date (date_key, date_label)
SELECT
    today() - (number % 4475)   AS date_key,
    toString(today() - (number % 4475))  AS date_label
FROM numbers(4474);

INSERT INTO mdm.counterparty
    (counterparty_name, counterparty_id, country, region, sector,
     credit_rating, is_active, onboarded_date, contact_email, legal_entity)
SELECT
    concat('Counterparty_', toString(number))                                  AS counterparty_name,
    toInt32(number)                                                            AS counterparty_id,
    arrayElement(['AU','NZ','JP','US','GB'], (rand() % 5) + 1)               AS country,
    arrayElement(['APAC','EMEA','AMER'], (rand() % 3) + 1)                   AS region,
    arrayElement(['Energy','Finance','Industrial'], (rand() % 3) + 1)         AS sector,
    arrayElement(['AAA','AA','A','BBB','BB'], (rand() % 5) + 1)              AS credit_rating,
    toBool(rand() % 2)                                                        AS is_active,
    today() - (rand() % 3650)                                                 AS onboarded_date,
    concat('contact', toString(number), '@example.com')                       AS contact_email,
    concat('Legal Entity ', toString(number))                                 AS legal_entity
FROM numbers(19);

INSERT INTO nz.generation_units
    (unit_id, unit_name, fuel_type, capacity_mw, owner, region,
     commissioning_date, latitude, longitude)
SELECT
    concat('NZU', toString(number))                                           AS unit_id,
    concat('NZ Gen Unit ', toString(number))                                  AS unit_name,
    arrayElement(['Wind','Hydro','Gas','Geothermal','Solar'], (rand()%5)+1)  AS fuel_type,
    toDecimal64(randUniform(1, 500), 3)                                      AS capacity_mw,
    concat('Owner_', toString(rand() % 10))                                  AS owner,
    arrayElement(['NI','SI'], (rand() % 2) + 1)                             AS region,
    today() - (rand() % 7300)                                                AS commissioning_date,
    -46.0 + randUniform(0, 14)                                               AS latitude,
    166.0 + randUniform(0, 12)                                               AS longitude
FROM numbers(111);

-- ============================================================
-- datacapture tables (scale down from prod row counts for local)
-- Production hkpug5ii1l25n = 4.8B rows; use 500K locally
-- ============================================================

INSERT INTO datacapture.hkpug5ii1l25n
SELECT
    now64(3) - toIntervalSecond(intDiv(number, 10) * 300)                    AS model_run_datetime_utc,
    toInt32(rand() % 100)                                                    AS id,
    now64(3) - toIntervalSecond(number * 300)                                AS interval_utc,
    arrayElement(['LKBANK1','CULLRGN1','MACGEN1','ARWF1','VMIN1'], (rand()%5)+1) AS duid,
    arrayElement(['NSW1','QLD1','VIC1','SA1','TAS1'], (rand() % 5) + 1)     AS region,
    arrayElement(['Wind','Hydro','Gas','Coal','Solar'], (rand() % 5) + 1)   AS fuel_type,
    toDecimal128(randUniform(0, 500), 6)                                     AS value_mw,
    toDecimal128(randUniform(0, 500), 6)                                     AS forecast_mw,
    arrayElement(['PREDISPATCH','DISPATCH','P5MIN'], (rand() % 3) + 1)      AS run_type,
    toUInt8(1)                                                               AS version
FROM numbers(500000);

INSERT INTO datacapture.hkaggineq5gd7
SELECT
    now64(3) - toIntervalSecond(number * 60)                                 AS issue_datetime_utc,
    toInt32(rand() % 200)                                                    AS id,
    arrayElement(['PRICE','DEMAND','GENERATION','LOAD'], (rand() % 4) + 1)  AS tag,
    now64(3) - toIntervalSecond(number * 60)                                 AS value_datetime_utc,
    toDecimal128(randUniform(-1000.0, 15000.0), 6)                           AS value_decimal,
    NULL                                                                     AS value_string,
    now64(3)                                                                 AS last_modified_utc,
    toUInt8(1)                                                               AS version
FROM numbers(200000);

INSERT INTO datacapture.fvow3t4chjeqj
SELECT
    now64(3) - toIntervalSecond(number * 300)                               AS last_changed_datetime_utc,
    now64(3) - toIntervalSecond(number * 300)                               AS solution_datetime_utc,
    arrayElement(['NSW1','QLD1','VIC1','SA1','TAS1'], (rand() % 5) + 1)    AS region_id,
    toDecimal128(randUniform(1000, 8000), 6)                                AS totaldemand,
    toDecimal128(randUniform(1000, 9000), 6)                                AS availablegeneration,
    toDecimal128(randUniform(500, 2000), 6)                                 AS availableload,
    toDecimal128(randUniform(800, 7000), 6)                                 AS clearedgeneration,
    toDecimal128(randUniform(-1000.0, 15000.0), 6)                          AS rrp,
    toDecimal128(randUniform(0, 1000), 6)                                   AS raise6secrrp,
    toDecimal128(randUniform(0, 1000), 6)                                   AS raise60secrrp,
    toDecimal128(randUniform(0, 1000), 6)                                   AS raise5minrrp,
    toDecimal128(randUniform(0, 500), 6)                                    AS raiseregrrp,
    toDecimal128(randUniform(0, 500), 6)                                    AS lower6secrrp,
    toDecimal128(randUniform(0, 500), 6)                                    AS lower60secrrp,
    toDecimal128(randUniform(0, 500), 6)                                    AS lower5minrrp,
    toDecimal128(randUniform(0, 500), 6)                                    AS lowerregrrp,
    toDecimal128(randUniform(0, 2000), 6)                                   AS totalintermittentgeneration,
    toDecimal128(randUniform(1000, 8000), 6)                                AS demand_and_nonschedgen,
    toDecimal128(randUniform(0, 1000), 6)                                   AS dispatchableload,
    toUInt8(1)                                                              AS version
FROM numbers(50000);

-- ============================================================
-- Validation (mirrors §8 of the runbook)
-- ============================================================

SELECT
    database,
    countIf(engine LIKE '%MergeTree') AS tables,
    countIf(engine = 'View')          AS views
FROM system.tables
WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA')
GROUP BY database
ORDER BY database;
