/* =========================================================
   Additive Daily Rollup with SummingMergeTree

   Metrics:
   - Event count
   - Total revenue
   - Total duration
   - Average duration derived at query time
   ========================================================= */


/* 1. Recreate derived objects */
DROP VIEW IF EXISTS analytics.mv_daily_additive_metrics;

DROP TABLE IF EXISTS analytics.daily_additive_metrics;


/* 2. Create the additive rollup table */
CREATE TABLE analytics.daily_additive_metrics
(
    event_date Date,

    event_type LowCardinality(String),

    platform LowCardinality(String),

    event_count UInt64,

    total_revenue Float64,

    total_duration_ms UInt64
)
ENGINE = SummingMergeTree
(
    (
        event_count,
        total_revenue,
        total_duration_ms
    )
)
PARTITION BY toYYYYMM(event_date)
ORDER BY
(
    event_date,
    event_type,
    platform
);


/* 3. Process future inserts automatically */
CREATE MATERIALIZED VIEW analytics.mv_daily_additive_metrics
TO analytics.daily_additive_metrics
AS
SELECT
    event_date,

    event_type,

    platform,

    count() AS event_count,

    sum(toFloat64(revenue)) AS total_revenue,

    sum(toUInt64(duration_ms)) AS total_duration_ms

FROM analytics.events

GROUP BY
    event_date,
    event_type,
    platform;


/* 4. Backfill existing events */
INSERT INTO analytics.daily_additive_metrics
SELECT
    event_date,

    event_type,

    platform,

    count() AS event_count,

    sum(toFloat64(revenue)) AS total_revenue,

    sum(toUInt64(duration_ms)) AS total_duration_ms

FROM analytics.events

GROUP BY
    event_date,
    event_type,
    platform;


/* 5. Verify daily metrics */
SELECT
    event_date,

    event_type,

    platform,

    sum(event_count) AS total_events,

    round
    (
        sum(total_revenue),
        2
    ) AS total_revenue,

    round
    (
        sum(total_duration_ms) / sum(event_count),
        2
    ) AS average_duration_ms

FROM analytics.daily_additive_metrics

GROUP BY
    event_date,
    event_type,
    platform

ORDER BY
    event_date DESC,
    total_events DESC

LIMIT 20;


/* 6. Compare table sizes */
SELECT
    table,

    sum(rows) AS rows,

    formatReadableSize
    (
        sum(bytes_on_disk)
    ) AS disk_size

FROM system.parts

WHERE database = 'analytics'

  AND table IN
  (
      'events',
      'daily_event_metrics',
      'daily_additive_metrics'
  )

  AND active

GROUP BY table

ORDER BY table;


/* 7. Prepare benchmark */
SYSTEM DROP QUERY CACHE;

SET use_query_cache = 0;

SET log_queries = 1;


/* 8. Benchmark raw-table additive metrics */
SET log_comment = 'raw_additive_benchmark';

SELECT
    count() AS total_events,

    round
    (
        sum(toFloat64(revenue)),
        2
    ) AS total_revenue,

    round
    (
        avg(toFloat64(duration_ms)),
        2
    ) AS average_duration_ms

FROM analytics.events

WHERE event_date >= today() - 30;

SET log_comment = '';

SYSTEM FLUSH LOGS;


/* 9. Benchmark additive rollup */
SET log_comment = 'additive_rollup_benchmark';

SELECT
    sum(event_count) AS total_events,

    round
    (
        sum(total_revenue),
        2
    ) AS total_revenue,

    round
    (
        sum(total_duration_ms) / sum(event_count),
        2
    ) AS average_duration_ms

FROM analytics.daily_additive_metrics

WHERE event_date >= today() - 30;

SET log_comment = '';

SYSTEM FLUSH LOGS;


/* 10. Display only the actual benchmark queries */
SELECT
    log_comment AS benchmark,

    query_duration_ms,

    read_rows,

    formatReadableSize(read_bytes) AS data_read,

    formatReadableSize(memory_usage) AS memory_used,

    left
    (
        replaceRegexpAll
        (
            query,
            '\\s+',
            ' '
        ),
        120
    ) AS executed_query

FROM system.query_log

WHERE type = 'QueryFinish'

  AND
  (
      (
          log_comment = 'raw_additive_benchmark'

          AND position
          (
              query,
              'FROM analytics.events'
          ) > 0
      )

      OR

      (
          log_comment = 'additive_rollup_benchmark'

          AND position
          (
              query,
              'FROM analytics.daily_additive_metrics'
          ) > 0
      )
  )

ORDER BY event_time DESC

LIMIT 1 BY log_comment;