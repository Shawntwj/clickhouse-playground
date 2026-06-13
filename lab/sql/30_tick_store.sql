-- ============================================================
-- 30: TICK STORE — market data is ClickHouse's home turf
-- ============================================================
-- Quant shops run tick stores on exactly this engine. Your 5-min bars are
-- not a constraint of ClickHouse — scrape at tick/second granularity and
-- let MVs build every coarser granularity for free.

-- ---------- A. The tick table: codecs were MADE for this ----------
CREATE TABLE lab.ticks
(
    symbol   LowCardinality(String),
    ts       DateTime64(3) CODEC(DoubleDelta, ZSTD),  -- ms precision
    price    Float64       CODEC(Gorilla, ZSTD),      -- slow-changing floats
    size     UInt32        CODEC(T64, ZSTD),
    side     Enum8('buy' = 1, 'sell' = -1)
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(ts)              -- daily: instant drops, fast backfills
ORDER BY (symbol, ts);                   -- ALL queries are "symbol over time"

-- Simulate a day of ticks: random walks for 20 symbols, ~5M ticks.
INSERT INTO lab.ticks
SELECT
    concat('SYM', toString(number % 20))                       AS symbol,
    toDateTime64(today(), 3) + toIntervalMillisecond(intDiv(number, 20) * 350) AS ts,
    100 + (number % 20) * 10
        + 3 * sin(intDiv(number, 20) / 5000)                   -- drift
        + (randNormal(0, 0.15))                                AS price,
    1 + rand() % 500                                           AS size,
    if(rand() % 2 = 0, 'buy', 'sell')                          AS side
FROM numbers_mt(5000000);

-- Check compression — tick data routinely compresses 10-20x with these codecs:
SELECT name, formatReadableSize(data_compressed_bytes) c,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns WHERE table = 'ticks' AND database = 'lab';

-- ---------- B. OHLCV bars as MVs: every granularity, computed at ingest ----------
CREATE TABLE lab.bars_1m
(
    symbol LowCardinality(String),
    bar    DateTime,
    open   AggregateFunction(argMin, Float64, DateTime64(3)),
    high   SimpleAggregateFunction(max, Float64),
    low    SimpleAggregateFunction(min, Float64),
    close  AggregateFunction(argMax, Float64, DateTime64(3)),
    volume SimpleAggregateFunction(sum, UInt64),
    trades SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
ORDER BY (symbol, bar);

CREATE MATERIALIZED VIEW lab.bars_1m_mv TO lab.bars_1m AS
SELECT
    symbol,
    toStartOfMinute(ts)            AS bar,
    argMinState(price, ts)         AS open,
    max(price)                     AS high,
    min(price)                     AS low,
    argMaxState(price, ts)         AS close,
    sum(toUInt64(size))            AS volume,
    count()                        AS trades
FROM lab.ticks
GROUP BY symbol, bar;

-- Backfill existing ticks (MVs only see new inserts):
INSERT INTO lab.bars_1m
SELECT symbol, toStartOfMinute(ts), argMinState(price, ts), max(price),
       min(price), argMaxState(price, ts), sum(toUInt64(size)), count()
FROM lab.ticks GROUP BY 1, 2;

-- Read bars (note -Merge for the argMin/argMax states):
SELECT symbol, bar,
       argMinMerge(open) AS o, max(high) AS h, min(low) AS l,
       argMaxMerge(close) AS c, sum(volume) AS v
FROM lab.bars_1m
WHERE symbol = 'SYM7'
GROUP BY symbol, bar ORDER BY bar
LIMIT 10;
-- Chain another MV on lab.bars_1m for 5m/1h bars — MVs cascade. Your old
-- 5-min granularity becomes just one tier of a pyramid that starts at ticks.
-- Live loop: keep inserting ticks (async_insert!) and watch bars appear
-- in Grafana within a second.

-- ---------- C. ASOF JOIN: the killer feature for market data ----------
-- "For each trade, what was the prevailing quote AT THAT MOMENT?"
-- In most databases this is a correlated-subquery nightmare. Here:
CREATE TABLE lab.quotes
(
    symbol LowCardinality(String),
    ts     DateTime64(3) CODEC(DoubleDelta, ZSTD),
    bid    Float64 CODEC(Gorilla, ZSTD),
    ask    Float64 CODEC(Gorilla, ZSTD)
)
ENGINE = MergeTree ORDER BY (symbol, ts);

INSERT INTO lab.quotes
SELECT concat('SYM', toString(number % 20)),
       toDateTime64(today(), 3) + toIntervalMillisecond(intDiv(number, 20) * 500),
       100 + (number % 20) * 10 - 0.05 + randNormal(0, 0.1),
       100 + (number % 20) * 10 + 0.05 + randNormal(0, 0.1)
FROM numbers_mt(3000000);

-- Effective spread per trade: join each tick to the LATEST quote <= tick time
SELECT
    t.symbol,
    count()                                        AS trades,
    round(avg(t.price - (q.bid + q.ask) / 2), 4)   AS avg_px_vs_mid,
    round(avg(q.ask - q.bid), 4)                   AS avg_spread
FROM lab.ticks AS t
ASOF JOIN lab.quotes AS q
    ON t.symbol = q.symbol AND t.ts >= q.ts
GROUP BY t.symbol
ORDER BY t.symbol;
-- ASOF JOIN = equality keys + ONE inequality on time. Nearest-in-the-past
-- matching at MergeTree scan speed. This single feature is why finance
-- adopted ClickHouse — and it's exactly what aligning multi-source
-- scraped feeds (prices, funding, sentiment) requires.
