-- ============================================================
-- Exercise 4: Side-by-side benchmark — FINAL vs Dictionary
--
-- Run this after completing exercises 01–03.
-- Results also appear live in the Grafana "Query Performance"
-- dashboard — filter by label to compare the two approaches.
-- ============================================================

-- Tag queries with a comment so Grafana can distinguish them.
-- ClickHouse records the raw SQL in system.query_log.

-- ── Round 1: FINAL join (baseline) ──────────────────────────
-- label: final_join
SELECT
    toStartOfHour(d.interval_utc)     AS hour_utc,
    d.region,
    avg(d.value_mw)                   AS avg_mw,
    any(h.holiday_name)               AS holiday_name
FROM read.hkpug5ii1l25n d
LEFT JOIN read.trading_holiday h
    ON toDate(d.interval_utc) = h.date
   AND d.region                = h.area
   AND h.calendar              = 'AEMO'
GROUP BY hour_utc, d.region
ORDER BY hour_utc DESC
LIMIT 100;

-- ── Round 2: Dictionary lookup (optimized) ───────────────────
-- label: dict_lookup
SELECT
    toStartOfHour(interval_utc)                                                        AS hour_utc,
    region,
    avg(value_mw)                                                                      AS avg_mw,
    dictGetOrDefault('tech.trading_holiday_dict', 'holiday_name',
        (toDate(interval_utc), region, 'AEMO'), '')                                    AS holiday_name
FROM read.hkpug5ii1l25n
GROUP BY hour_utc, region, holiday_name
ORDER BY hour_utc DESC
LIMIT 100;

-- ── Compare results from system.query_log ────────────────────
-- Run this a minute after the two queries above to see timing
SELECT
    if(query LIKE '%final_join%',   'final_join',
       if(query LIKE '%dict_lookup%', 'dict_lookup', 'other')) AS approach,
    count()                       AS runs,
    avg(query_duration_ms)        AS avg_ms,
    min(query_duration_ms)        AS min_ms,
    max(query_duration_ms)        AS max_ms,
    avg(memory_usage) / 1e6       AS avg_memory_mb,
    avg(read_rows)                AS avg_rows_read
FROM system.query_log
WHERE
    event_date = today()
    AND type    = 'QueryFinish'
    AND (query LIKE '%final_join%' OR query LIKE '%dict_lookup%')
GROUP BY approach
ORDER BY approach;

-- ── Bonus: measure dictionary overhead (load time + memory) ──
SELECT
    name,
    status,
    element_count,
    round(bytes_allocated / 1e3, 1)   AS kb_in_memory,
    load_duration_ms,
    last_successful_update_time
FROM system.dictionaries
ORDER BY bytes_allocated DESC;
