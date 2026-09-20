/* =========================================================
   Daily Aggregation with AggregatingMergeTree

   This script:
   1. Creates a daily aggregate table
   2. Creates a Materialized View for future inserts
   3. Backfills existing events
   4. Validates aggregate results
   5. Compares storage usage
   6. Benchmarks raw and pre-aggregated queries
   ========================================================= */


/* =========================================================
   1. Clean up derived objects

   These objects contain derived data and can safely be
   recreated during this lab.
   ========================================================= */

DROP VIEW IF EXISTS analytics.mv_daily_event_metrics;

DROP TABLE IF EXISTS analytics.daily_event_metrics;


/* =========================================================
   2. Create the pre-aggregated target table
   ========================================================= */

CREATE TABLE analytics.daily_event_metrics
(
    event_date Date,

    event_type LowCardinality(String),

    platform LowCardinality(String),

    event_count_state AggregateFunction(count),

    unique_users_state AggregateFunction
    (
        uniqCombined64,
        UInt64
    ),

    unique_sessions_state AggregateFunction
    (
        uniqCombined64,
        UUID
    ),

    revenue_state AggregateFunction
    (
        sum,
        Float64
    ),

    duration_avg_state AggregateFunction
    (
        avg,
        Float64
    )
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(event_date)
ORDER BY
(
    event_date,
    event_type,
    platform
);


/* =========================================================
   3. Create Materialized View

   New rows inserted into analytics.events will automatically
   be aggregated and written into daily_event_metrics.
   ========================================================= */

CREATE MATERIALIZED VIEW analytics.mv_daily_event_metrics
TO analytics.daily_event_metrics
AS
SELECT
    event_date,

    event_type,

    platform,

    countState() AS event_count_state,

    uniqCombined64State(user_id) AS unique_users_state,

    uniqCombined64State(session_id) AS unique_sessions_state,

    sumState
    (
        toFloat64(revenue)
    ) AS revenue_state,

    avgState
    (
        toFloat64(duration_ms)
    ) AS duration_avg_state

FROM analytics.events

GROUP BY
    event_date,
    event_type,
    platform;


/* =========================================================
   4. Backfill existing data

   A Materialized View only processes new inserts.
   Therefore, the existing one million events must be
   inserted into the aggregate table manually.
   ========================================================= */

INSERT INTO analytics.daily_event_metrics
SELECT
    event_date,

    event_type,

    platform,

    countState(),

    uniqCombined64State(user_id),

    uniqCombined64State(session_id),

    sumState
    (
        toFloat64(revenue)
    ),

    avgState
    (
        toFloat64(duration_ms)
    )

FROM analytics.events

GROUP BY
    event_date,
    event_type,
    platform;


/* =========================================================
   5. Verify aggregated results
   ========================================================= */

SELECT
    event_date,

    event_type,

    platform,

    countMerge(event_count_state) AS total_events,

    uniqCombined64Merge(unique_users_state) AS unique_users,

    uniqCombined64Merge(unique_sessions_state) AS unique_sessions,

    round
    (
        sumMerge(revenue_state),
        2
    ) AS total_revenue,

    round
    (
        avgMerge(duration_avg_state),
        2
    ) AS average_duration_ms

FROM analytics.daily_event_metrics

GROUP BY
    event_date,
    event_type,
    platform

ORDER BY
    event_date DESC,
    total_events DESC

LIMIT 20;


/* =========================================================
   6. Compare row count and storage size
   ========================================================= */

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
      'daily_event_metrics'
  )

  AND active

GROUP BY table

ORDER BY table;


/* =========================================================
   7. Prepare a fair benchmark

   Disable the ClickHouse query-result cache so both queries
   are actually executed.
   ========================================================= */

SYSTEM DROP QUERY CACHE;

SET use_query_cache = 0;

SET log_queries = 1;


/* =========================================================
   8. Benchmark the raw events table
   ========================================================= */

SET log_comment = 'raw_table_benchmark';

SELECT
    count() AS total_events,

    uniqCombined64(user_id) AS unique_users,

    round
    (
        sum(toFloat64(revenue)),
        2
    ) AS total_revenue

FROM analytics.events

WHERE event_date >= today() - 30;


/*
   Reset the label before flushing the logs so that
   SYSTEM FLUSH LOGS is not mistaken for the benchmark query.
*/

SET log_comment = '';

SYSTEM FLUSH LOGS;


/* =========================================================
   9. Benchmark the Materialized View
   ========================================================= */

SET log_comment = 'materialized_view_benchmark';

SELECT
    countMerge(event_count_state) AS total_events,

    uniqCombined64Merge(unique_users_state) AS unique_users,

    round
    (
        sumMerge(revenue_state),
        2
    ) AS total_revenue

FROM analytics.daily_event_metrics

WHERE event_date >= today() - 30;


/*
   Reset the label before writing pending query-log records.
*/

SET log_comment = '';

SYSTEM FLUSH LOGS;


/* =========================================================
   10. Display the actual benchmark queries

   The additional query-text conditions prevent SET and
   SYSTEM FLUSH LOGS commands from appearing in the result.
   ========================================================= */

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
          log_comment = 'raw_table_benchmark'

          AND position
          (
              query,
              'FROM analytics.events'
          ) > 0
      )

      OR

      (
          log_comment = 'materialized_view_benchmark'

          AND position
          (
              query,
              'FROM analytics.daily_event_metrics'
          ) > 0
      )
  )

ORDER BY event_time DESC

LIMIT 1 BY log_comment;