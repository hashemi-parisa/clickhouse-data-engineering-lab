/* ============================================================
   Step 7: TTL and Data Lifecycle Management

   Goals:
   - Add a safe 365-day retention policy to analytics.events
   - Inspect the expiration range
   - Demonstrate automatic deletion using an isolated table
   ============================================================ */


/* ------------------------------------------------------------
   1. Inspect the current event-time range
   ------------------------------------------------------------ */

SELECT
    count() AS total_rows,
    min(event_time) AS oldest_event,
    max(event_time) AS newest_event,
    dateDiff('day', min(event_time), max(event_time)) AS covered_days
FROM analytics.events;


/* ------------------------------------------------------------
   2. Add a 365-day retention policy

   Rows become eligible for deletion 365 days after event_time.
   Existing synthetic data is recent, so this operation is safe.
   ------------------------------------------------------------ */

ALTER TABLE analytics.events
MODIFY TTL event_time + INTERVAL 365 DAY DELETE;


/* ------------------------------------------------------------
   3. Verify the table-level TTL definition
   ------------------------------------------------------------ */

SELECT
    database,
    name AS table_name,
    engine,
    create_table_query
FROM system.tables
WHERE database = 'analytics'
  AND name = 'events';


/* ------------------------------------------------------------
   4. Preview the retention timeline

   This does not delete anything.
   ------------------------------------------------------------ */

SELECT
    min(event_time) AS oldest_event,
    min(event_time) + INTERVAL 365 DAY AS first_expiration,
    max(event_time) AS newest_event,
    max(event_time) + INTERVAL 365 DAY AS last_expiration
FROM analytics.events;


/* ------------------------------------------------------------
   5. Show rows by expiration month
   ------------------------------------------------------------ */

SELECT
    toStartOfMonth(event_time + INTERVAL 365 DAY) AS expiration_month,
    count() AS rows_to_expire
FROM analytics.events
GROUP BY expiration_month
ORDER BY expiration_month;


/* ============================================================
   TTL demonstration
   ============================================================ */


/* ------------------------------------------------------------
   6. Recreate an isolated TTL demonstration table

   This operation affects only ttl_events_demo.
   ------------------------------------------------------------ */

DROP TABLE IF EXISTS analytics.ttl_events_demo;

CREATE TABLE analytics.ttl_events_demo
(
    event_id UUID DEFAULT generateUUIDv4(),
    event_time DateTime64(3, 'UTC'),
    event_type LowCardinality(String),
    payload String
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (event_time, event_id)
TTL event_time + INTERVAL 30 DAY DELETE
SETTINGS merge_with_ttl_timeout = 60;


/* ------------------------------------------------------------
   7. Insert expired and active records
   ------------------------------------------------------------ */

INSERT INTO analytics.ttl_events_demo
    (event_time, event_type, payload)
VALUES
    (now64(3, 'UTC') - INTERVAL 60 DAY, 'expired_event', 'older than 30 days'),
    (now64(3, 'UTC') - INTERVAL 45 DAY, 'expired_event', 'older than 30 days'),
    (now64(3, 'UTC') - INTERVAL 10 DAY, 'active_event',  'within retention period'),
    (now64(3, 'UTC') - INTERVAL 1 DAY,  'active_event',  'recent event');


/* ------------------------------------------------------------
   8. Inspect rows before the TTL merge
   ------------------------------------------------------------ */

SELECT
    event_time,
    event_type,
    payload,
    if(
        event_time < now64(3, 'UTC') - INTERVAL 30 DAY,
        'expired',
        'active'
    ) AS lifecycle_status
FROM analytics.ttl_events_demo
ORDER BY event_time;


/* ------------------------------------------------------------
   9. Count active and expired rows before cleanup
   ------------------------------------------------------------ */

SELECT
    count() AS total_rows_before_ttl,
    countIf(
        event_time < now64(3, 'UTC') - INTERVAL 30 DAY
    ) AS expired_rows,
    countIf(
        event_time >= now64(3, 'UTC') - INTERVAL 30 DAY
    ) AS active_rows
FROM analytics.ttl_events_demo;


/* ------------------------------------------------------------
   10. Force a merge for demonstration purposes

   In production, TTL normally runs automatically during
   background merges. OPTIMIZE FINAL should not be run routinely
   on large production tables.
   ------------------------------------------------------------ */

OPTIMIZE TABLE analytics.ttl_events_demo FINAL;


/* ------------------------------------------------------------
   11. Verify that expired rows were removed
   ------------------------------------------------------------ */

SELECT
    count() AS total_rows_after_ttl,
    min(event_time) AS oldest_remaining_event,
    max(event_time) AS newest_remaining_event
FROM analytics.ttl_events_demo;


/* ------------------------------------------------------------
   12. Display the remaining active records
   ------------------------------------------------------------ */

SELECT
    event_time,
    event_type,
    payload
FROM analytics.ttl_events_demo
ORDER BY event_time;


/* ------------------------------------------------------------
   13. Inspect active storage parts
   ------------------------------------------------------------ */

SELECT
    table,
    partition,
    name AS part_name,
    rows,
    formatReadableSize(bytes_on_disk) AS disk_size,
    min_time,
    max_time
FROM system.parts
WHERE database = 'analytics'
  AND table = 'ttl_events_demo'
  AND active
ORDER BY partition;