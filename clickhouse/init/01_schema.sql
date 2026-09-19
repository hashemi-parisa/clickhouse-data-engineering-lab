CREATE DATABASE IF NOT EXISTS analytics;

CREATE TABLE IF NOT EXISTS analytics.events
(
    event_id UUID DEFAULT generateUUIDv4(),
    event_time DateTime64(3, 'UTC'),
    event_date Date MATERIALIZED toDate(event_time),
    user_id UInt64,
    event_type LowCardinality(String),
    platform LowCardinality(String),
    country_code FixedString(2),
    session_id UUID,
    duration_ms UInt32,
    revenue Decimal(12, 2),
    properties String DEFAULT '{}'
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_type, event_date, user_id, event_time)
SETTINGS index_granularity = 8192;