/* ============================================================
   Step 8: Data Skipping Index Benchmark

   Goals:
   - Build a controlled 3-million-row dataset
   - Run a query without a skip index
   - Add and materialize a set index
   - Verify index usage with EXPLAIN
   - Compare rows read, bytes read, duration, and memory
   ============================================================ */


/* ------------------------------------------------------------
   1. Recreate the demonstration table
   ------------------------------------------------------------ */

DROP TABLE IF EXISTS analytics.skip_index_demo;

CREATE TABLE analytics.skip_index_demo
(
    event_id UInt64,
    event_time DateTime('UTC'),
    status_code UInt16,
    endpoint LowCardinality(String),
    response_time_ms UInt32,
    message String
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id)
SETTINGS index_granularity = 8192;


/* ------------------------------------------------------------
   2. Generate three million deterministic records

   Most records have status code 200.
   Only 10,000 consecutive records have status code 500.

   Because error records are grouped together, most granules
   do not contain status_code = 500 and can be skipped.
   ------------------------------------------------------------ */

INSERT INTO analytics.skip_index_demo
SELECT
    number AS event_id,

    toDateTime('2026-01-01 00:00:00', 'UTC')
        + toIntervalSecond(number) AS event_time,

    if(
        number >= 1500000 AND number < 1510000,
        500,
        200
    ) AS status_code,

    arrayElement(
        ['/api/search', '/api/booking', '/api/payment', '/api/profile'],
        1 + (number % 4)
    ) AS endpoint,

    toUInt32(20 + (number % 1980)) AS response_time_ms,

    if(
        status_code = 500,
        'internal server error',
        'request completed successfully'
    ) AS message

FROM numbers(3000000);


/* ------------------------------------------------------------
   3. Validate the generated dataset
   ------------------------------------------------------------ */

SELECT
    count() AS total_rows,
    countIf(status_code = 200) AS successful_requests,
    countIf(status_code = 500) AS server_errors,
    min(event_time) AS first_event,
    max(event_time) AS last_event
FROM analytics.skip_index_demo;


/* ------------------------------------------------------------
   4. Baseline benchmark without data-skipping indexes
   ------------------------------------------------------------ */

SET use_skip_indexes = 0;
SET log_comment = 'skip_index_disabled';

SELECT
    count() AS error_count,
    min(event_time) AS first_error,
    max(event_time) AS last_error,
    round(avg(response_time_ms), 2) AS avg_response_time_ms
FROM analytics.skip_index_demo
WHERE status_code = 500;


/* ------------------------------------------------------------
   5. Add a set data-skipping index

   set(10) stores up to ten distinct status codes per indexed
   block. This is suitable because local cardinality is low.
   ------------------------------------------------------------ */

ALTER TABLE analytics.skip_index_demo
ADD INDEX IF NOT EXISTS idx_status_code
    status_code
    TYPE set(10)
    GRANULARITY 1;


/* ------------------------------------------------------------
   6. Materialize the index for existing data
   ------------------------------------------------------------ */

ALTER TABLE analytics.skip_index_demo
MATERIALIZE INDEX idx_status_code
SETTINGS mutations_sync = 1;


/* ------------------------------------------------------------
   7. Inspect the index metadata
   ------------------------------------------------------------ */

SELECT
    database,
    table,
    name,
    type,
    expr,
    granularity
FROM system.data_skipping_indices
WHERE database = 'analytics'
  AND table = 'skip_index_demo';


/* ------------------------------------------------------------
   8. Inspect index pruning in the execution plan
   ------------------------------------------------------------ */

SET use_skip_indexes = 1;

EXPLAIN indexes = 1
SELECT
    count() AS error_count,
    min(event_time) AS first_error,
    max(event_time) AS last_error,
    round(avg(response_time_ms), 2) AS avg_response_time_ms
FROM analytics.skip_index_demo
WHERE status_code = 500
SETTINGS force_data_skipping_indices = 'idx_status_code';


/* ------------------------------------------------------------
   9. Benchmark with the data-skipping index enabled

   force_data_skipping_indices makes the validation explicit:
   the query fails if ClickHouse cannot use the named index.
   ------------------------------------------------------------ */

SET log_comment = 'skip_index_enabled';

SELECT
    count() AS error_count,
    min(event_time) AS first_error,
    max(event_time) AS last_error,
    round(avg(response_time_ms), 2) AS avg_response_time_ms
FROM analytics.skip_index_demo
WHERE status_code = 500
SETTINGS force_data_skipping_indices = 'idx_status_code';


/* ------------------------------------------------------------
   10. Flush query logs
   ------------------------------------------------------------ */

SET log_comment = '';

SYSTEM FLUSH LOGS;


/* ------------------------------------------------------------
   11. Compare both benchmark executions
   ------------------------------------------------------------ */

SELECT
    log_comment AS benchmark,
    query_duration_ms,
    read_rows,
    formatReadableQuantity(read_rows) AS readable_rows,
    formatReadableSize(read_bytes) AS data_read,
    formatReadableSize(memory_usage) AS memory_used
FROM system.query_log
WHERE type = 'QueryFinish'
  AND log_comment IN
  (
      'skip_index_disabled',
      'skip_index_enabled'
  )
  AND position(query, 'FROM analytics.skip_index_demo') > 0
ORDER BY event_time DESC
LIMIT 1 BY log_comment;


/* ------------------------------------------------------------
   12. Calculate the reduction in rows read
   ------------------------------------------------------------ */

WITH
    (
        SELECT read_rows
        FROM system.query_log
        WHERE type = 'QueryFinish'
          AND log_comment = 'skip_index_disabled'
          AND position(query, 'FROM analytics.skip_index_demo') > 0
        ORDER BY event_time DESC
        LIMIT 1
    ) AS rows_without_index,

    (
        SELECT read_rows
        FROM system.query_log
        WHERE type = 'QueryFinish'
          AND log_comment = 'skip_index_enabled'
          AND position(query, 'FROM analytics.skip_index_demo') > 0
        ORDER BY event_time DESC
        LIMIT 1
    ) AS rows_with_index

SELECT
    rows_without_index,
    rows_with_index,
    round(
        100 * (rows_without_index - rows_with_index)
            / rows_without_index,
        2
    ) AS rows_read_reduction_percent;


/* ------------------------------------------------------------
   13. Inspect active parts
   ------------------------------------------------------------ */

SELECT
    partition,
    name AS part_name,
    rows,
    marks,
    formatReadableSize(bytes_on_disk) AS disk_size
FROM system.parts
WHERE database = 'analytics'
  AND table = 'skip_index_demo'
  AND active
ORDER BY partition;


/* ------------------------------------------------------------
   14. Reset session settings
   ------------------------------------------------------------ */

SET use_skip_indexes = 1;
SET log_comment = '';