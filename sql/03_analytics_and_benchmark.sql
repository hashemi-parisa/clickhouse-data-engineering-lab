/* =========================================================
   ClickHouse Analytics and Performance Benchmark
   Dataset: analytics.events
   ========================================================= */


/* 1. Dataset overview */
SELECT
    count() AS total_events,
    uniqExact(user_id) AS unique_users,
    uniqExact(session_id) AS unique_sessions,
    min(event_time) AS first_event,
    max(event_time) AS last_event,
    round(sum(revenue), 2) AS total_revenue
FROM analytics.events;


/* 2. Event type distribution */
SELECT
    event_type,
    count() AS event_count,
    round(event_count * 100.0 / sum(event_count) OVER (), 2) AS percentage
FROM analytics.events
GROUP BY event_type
ORDER BY event_count DESC;


/* 3. Daily active users */
SELECT
    event_date,
    count() AS total_events,
    uniqExact(user_id) AS daily_active_users,
    uniqExact(session_id) AS daily_sessions
FROM analytics.events
GROUP BY event_date
ORDER BY event_date;


/* 4. Platform performance */
SELECT
    platform,
    count() AS total_events,
    uniqExact(user_id) AS unique_users,
    round(sum(revenue), 2) AS total_revenue,
    round(avg(duration_ms), 2) AS average_duration_ms
FROM analytics.events
GROUP BY platform
ORDER BY total_events DESC;


/* 5. Country-level analytics */
SELECT
    country_code,
    count() AS total_events,
    uniqExact(user_id) AS unique_users,
    round(sum(revenue), 2) AS total_revenue
FROM analytics.events
GROUP BY country_code
ORDER BY total_events DESC;


/* 6. Event-processing latency percentiles */
SELECT
    event_type,
    round(quantileExact(0.50)(duration_ms), 2) AS p50_duration_ms,
    round(quantileExact(0.95)(duration_ms), 2) AS p95_duration_ms,
    round(quantileExact(0.99)(duration_ms), 2) AS p99_duration_ms
FROM analytics.events
GROUP BY event_type
ORDER BY event_type;


/* 7. Revenue trend */
SELECT
    event_date,
    round(sum(revenue), 2) AS daily_revenue,
    countIf(revenue > 0) AS revenue_generating_events
FROM analytics.events
GROUP BY event_date
ORDER BY event_date;


/* 8. Baseline benchmark for a recent-date query */
SET log_comment = 'baseline_recent_events';

SELECT
    count() AS total_events,
    uniqExact(user_id) AS unique_users,
    round(sum(revenue), 2) AS total_revenue
FROM analytics.events
WHERE event_date >= today() - 30;


/* Write pending query-log records */
SYSTEM FLUSH LOGS;


/* 9. Retrieve benchmark metrics */
SELECT
    query_duration_ms,
    read_rows,
    formatReadableSize(read_bytes) AS data_read,
    formatReadableSize(memory_usage) AS memory_used
FROM system.query_log
WHERE type = 'QueryFinish'
  AND log_comment = 'baseline_recent_events'
ORDER BY event_time DESC
LIMIT 1;


/* Reset the query label */
SET log_comment = '';