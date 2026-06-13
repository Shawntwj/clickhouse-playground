#!/bin/bash
set -e

CH="docker exec -i clickhouse clickhouse-client -u admin --password admin"

run() {
    local label=$1
    local sql=$2
    echo "⏳ $label..."
    echo "$sql" | $CH
    echo "✅ $label done"
}

echo "=== Seeding ClickHouse ==="

run "utl.kafka_crossdb_connectors (27 rows)" "
INSERT INTO utl.kafka_crossdb_connectors (table_schema, table_name, kafka_topic)
SELECT
    arrayElement(['datacapture', 'read'], (rand() % 2) + 1),
    concat('topic_', toString(number)),
    concat('kafka.topic.', toString(number))
FROM numbers(27);"

run "tech.trading_holiday (1922 rows)" "
INSERT INTO tech.trading_holiday (date, area, calendar, holiday_name, is_partial)
SELECT
    today() - (number % 1095),
    arrayElement(['NSW1','QLD1','VIC1','SA1','TAS1'], (rand() % 5) + 1),
    arrayElement(['AEMO','ASX','NZX'], (rand() % 3) + 1),
    concat('Holiday_', toString(number % 30)),
    toBool(rand() % 2)
FROM numbers(1922);"

run "stg.date (4474 rows)" "
INSERT INTO stg.date (date_key, date_label)
SELECT
    today() - (number % 4475),
    toString(today() - (number % 4475))
FROM numbers(4474);"

run "mdm.counterparty (19 rows)" "
INSERT INTO mdm.counterparty (counterparty_name, counterparty_id, country, region, sector, credit_rating, is_active, onboarded_date, contact_email, legal_entity)
SELECT
    concat('Counterparty_', toString(number)),
    toInt32(number),
    arrayElement(['AU','NZ','JP','US','GB'], (rand() % 5) + 1),
    arrayElement(['APAC','EMEA','AMER'], (rand() % 3) + 1),
    arrayElement(['Energy','Finance','Industrial'], (rand() % 3) + 1),
    arrayElement(['AAA','AA','A','BBB','BB'], (rand() % 5) + 1),
    toBool(rand() % 2),
    today() - (rand() % 3650),
    concat('contact', toString(number), '@example.com'),
    concat('Legal Entity ', toString(number))
FROM numbers(19);"

run "nz.generation_units (111 rows)" "
INSERT INTO nz.generation_units (unit_id, unit_name, fuel_type, capacity_mw, owner, region, commissioning_date, latitude, longitude)
SELECT
    concat('NZU', toString(number)),
    concat('NZ Gen Unit ', toString(number)),
    arrayElement(['Wind','Hydro','Gas','Geothermal','Solar'], (rand()%5)+1),
    toDecimal64(randUniform(1, 500), 3),
    concat('Owner_', toString(rand() % 10)),
    arrayElement(['NI','SI'], (rand() % 2) + 1),
    today() - (rand() % 7300),
    -46.0 + randUniform(0, 14),
    166.0 + randUniform(0, 12)
FROM numbers(111);"

run "datacapture.hkpug5ii1l25n (500k rows) — this takes a while..." "
INSERT INTO datacapture.hkpug5ii1l25n
SELECT
    now64(3) - toIntervalSecond(intDiv(number, 10) * 300),
    toInt32(rand() % 100),
    now64(3) - toIntervalSecond(number * 300),
    arrayElement(['LKBANK1','CULLRGN1','MACGEN1','ARWF1','VMIN1'], (rand()%5)+1),
    arrayElement(['NSW1','QLD1','VIC1','SA1','TAS1'], (rand() % 5) + 1),
    arrayElement(['Wind','Hydro','Gas','Coal','Solar'], (rand() % 5) + 1),
    toDecimal128(randUniform(0, 500), 6),
    toDecimal128(randUniform(0, 500), 6),
    arrayElement(['PREDISPATCH','DISPATCH','P5MIN'], (rand() % 3) + 1),
    toUInt8(1)
FROM numbers(500000);"

run "datacapture.hkaggineq5gd7 (200k rows)" "
INSERT INTO datacapture.hkaggineq5gd7
SELECT
    now64(3) - toIntervalSecond(number * 60),
    toInt32(rand() % 200),
    arrayElement(['PRICE','DEMAND','GENERATION','LOAD'], (rand() % 4) + 1),
    now64(3) - toIntervalSecond(number * 60),
    toDecimal128(randUniform(-1000.0, 15000.0), 6),
    NULL,
    now64(3),
    toUInt8(1)
FROM numbers(200000);"

run "datacapture.fvow3t4chjeqj (50k rows)" "
INSERT INTO datacapture.fvow3t4chjeqj
SELECT
    now64(3) - toIntervalSecond(number * 300),
    now64(3) - toIntervalSecond(number * 300),
    arrayElement(['NSW1','QLD1','VIC1','SA1','TAS1'], (rand() % 5) + 1),
    toDecimal128(randUniform(1000, 8000), 6),
    toDecimal128(randUniform(1000, 9000), 6),
    toDecimal128(randUniform(500, 2000), 6),
    toDecimal128(randUniform(800, 7000), 6),
    toDecimal128(randUniform(-1000.0, 15000.0), 6),
    toDecimal128(randUniform(0, 1000), 6),
    toDecimal128(randUniform(0, 1000), 6),
    toDecimal128(randUniform(0, 1000), 6),
    toDecimal128(randUniform(0, 500), 6),
    toDecimal128(randUniform(0, 500), 6),
    toDecimal128(randUniform(0, 500), 6),
    toDecimal128(randUniform(0, 500), 6),
    toDecimal128(randUniform(0, 500), 6),
    toDecimal128(randUniform(0, 2000), 6),
    toDecimal128(randUniform(1000, 8000), 6),
    toDecimal128(randUniform(0, 1000), 6),
    toUInt8(1)
FROM numbers(50000);"

echo ""
echo "=== Validation ==="
docker exec -i clickhouse clickhouse-client -u admin --password admin --query \
    "SELECT database, countIf(engine LIKE '%MergeTree') AS tables, countIf(engine='View') AS views FROM system.tables WHERE database NOT IN ('system','information_schema','INFORMATION_SCHEMA') GROUP BY database ORDER BY database"

echo ""
echo "=== Done ==="
