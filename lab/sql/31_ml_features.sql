-- ============================================================
-- 31: ML PIPELINE — ClickHouse as your feature factory
-- ============================================================
-- The right division of labor:
--   ClickHouse: store everything, compute features over billions of rows,
--               generate labeled training sets in seconds, export Parquet.
--   Python/GPU: actually train the model.
-- Trying to make pandas do the feature pass over raw ticks is how laptops
-- die; trying to make ClickHouse do gradient descent is how projects die.
-- (One small exception at the bottom.)

-- ---------- A. Features via window functions, straight off the bars ----------
CREATE VIEW lab.features AS
WITH base AS (
    SELECT symbol, bar,
           argMaxMerge(close) AS close,
           sum(volume)        AS volume
    FROM lab.bars_1m
    GROUP BY symbol, bar
)
SELECT
    symbol, bar, close,
    -- log return over previous bar
    log(close / lagInFrame(close, 1) OVER w)                          AS ret_1,
    -- momentum: 5- and 20-bar returns
    log(close / lagInFrame(close, 5)  OVER w)                         AS ret_5,
    log(close / lagInFrame(close, 20) OVER w)                         AS ret_20,
    -- rolling volatility: stddev of close over trailing 20 bars
    stddevPop(close) OVER (PARTITION BY symbol ORDER BY bar
                           ROWS BETWEEN 19 PRECEDING AND CURRENT ROW) AS vol_20,
    -- volume z-score vs trailing 20 bars
    (volume - avg(volume) OVER (PARTITION BY symbol ORDER BY bar
                                ROWS BETWEEN 19 PRECEDING AND CURRENT ROW))
      / nullIf(stddevPop(volume) OVER (PARTITION BY symbol ORDER BY bar
                                ROWS BETWEEN 19 PRECEDING AND CURRENT ROW), 0) AS vol_z,
    -- THE LABEL: forward 5-bar return (leadInFrame looks into the future —
    -- only legal because we're building training data, never features!)
    log(leadInFrame(close, 5) OVER w / close)                         AS y_fwd_5
FROM base
WINDOW w AS (PARTITION BY symbol ORDER BY bar)
ORDER BY symbol, bar;

SELECT * FROM lab.features WHERE symbol = 'SYM7' LIMIT 5 OFFSET 25;
-- A full feature pass over every symbol, windowed, labeled — one query.
-- On real data this is the job that takes pandas an hour and CH seconds.

-- ---------- B. Reproducible train/test split, exported as Parquet ----------
-- Hash-based split = deterministic, no leakage from random state:
INSERT INTO FUNCTION file('/var/lib/clickhouse/user_files/train.parquet', Parquet)
SELECT * FROM lab.features
WHERE y_fwd_5 IS NOT NULL AND ret_20 IS NOT NULL
  AND cityHash64(symbol, bar) % 10 < 8;            -- 80%

INSERT INTO FUNCTION file('/var/lib/clickhouse/user_files/test.parquet', Parquet)
SELECT * FROM lab.features
WHERE y_fwd_5 IS NOT NULL AND ret_20 IS NOT NULL
  AND cityHash64(symbol, bar) % 10 >= 8;           -- 20%
-- Copy out:  docker cp ch:/var/lib/clickhouse/user_files/train.parquet .
-- Then in Python: pd.read_parquet / polars / torch — or skip the file
-- entirely with chDB (`pip install chdb`): the ClickHouse engine embedded
-- in-process, so df = chdb.query("SELECT ... ", "DataFrame") runs THIS SQL
-- inside your training script. clickhouse-connect is the client for the
-- server itself. Feature logic stays in one place: SQL.

-- ---------- C. The exception: in-database baseline models ----------
-- CH ships SGD linear/logistic regression as aggregate functions. Never
-- your production model — always your honesty check: if XGBoost can't beat
-- this, your features are the problem.
CREATE TABLE lab.baseline ENGINE = Memory AS
SELECT stochasticLinearRegressionState(0.01, 0.1, 32, 'Adam')
       (y_fwd_5, ret_1, ret_5, ret_20, vol_z) AS model
FROM lab.features
WHERE y_fwd_5 IS NOT NULL AND ret_20 IS NOT NULL AND vol_z IS NOT NULL
  AND cityHash64(symbol, bar) % 10 < 8;

WITH (SELECT model FROM lab.baseline) AS m
SELECT
    corr(pred, y_fwd_5)                  AS ic,          -- information coefficient
    avg(sign(pred) = sign(y_fwd_5))      AS hit_rate
FROM (
    SELECT evalMLMethod(m, ret_1, ret_5, ret_20, vol_z) AS pred, y_fwd_5
    FROM lab.features
    WHERE y_fwd_5 IS NOT NULL AND ret_20 IS NOT NULL AND vol_z IS NOT NULL
      AND cityHash64(symbol, bar) % 10 >= 8
);
-- (On this synthetic random walk, expect ~zero IC — correctly! A pipeline
-- that finds signal in noise is a broken pipeline. Now point it at real
-- scraped data.)

-- ---------- D. Model stacking, the ClickHouse way ----------
-- Stacked models = predictions from model A become features for model B.
-- Operationally: write every model's predictions BACK as a table
--   (symbol, bar, model_version, pred), ORDER BY (symbol, bar)
-- then ASOF/equi-join them into the feature view above. ClickHouse becomes
-- the ledger of all model outputs — which also gives you backtesting and
-- model monitoring (rolling IC per model_version) as plain SQL on the
-- same dashboard stack you already run.
