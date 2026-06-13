-- A pretend OLTP app database: the kind of thing you sync INTO ClickHouse.
CREATE TABLE customers (
    customer_id  INT PRIMARY KEY,
    name         TEXT NOT NULL,
    plan         TEXT NOT NULL,
    country      TEXT NOT NULL,
    updated_at   TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO customers (customer_id, name, plan, country)
SELECT
    g,
    'customer_' || g,
    (ARRAY['free','pro','enterprise'])[1 + g % 3],
    (ARRAY['US','DE','IN','BR','GB'])[1 + g % 5]
FROM generate_series(1, 10000) g;

CREATE TABLE orders (
    order_id    SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,
    amount      NUMERIC(10,2) NOT NULL,
    created_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO orders (customer_id, amount, created_at)
SELECT 1 + (random() * 9999)::int,
       (random() * 500)::numeric(10,2),
       now() - (random() * interval '30 days')
FROM generate_series(1, 100000);
