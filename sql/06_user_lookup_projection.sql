/* ============================================================
   Step 6: Optimizing user lookups with a covering projection
   ============================================================ */


/* ------------------------------------------------------------
   1. Remove the previous lightweight projection
   ------------------------------------------------------------ */

ALTER TABLE analytics.events
DROP PROJECTION IF EXISTS prj_user_id;


/* ------------------------------------------------------------
   2. Create a covering projection

   The benchmark only needs:
   - user_id
   - event_time
   - revenue

   Therefore, duplicating all table columns is unnecessary.
   ------------------------------------------------------------ */

ALTER TABLE analytics.events
ADD PROJECTION IF NOT EXISTS prj_user_lookup
(
    SELECT
        user_id,
        event_time,
        revenue
    ORDER BY
        user_id,
        event_time
);


/* ------------------------------------------------------------
   3. Build the projection for existing rows
   ------------------------------------------------------------ */

ALTER TABLE analytics.events
MATERIALIZE PROJECTION prj_user_lookup
SETTINGS mutations_sync = 1;


/* ------------------------------------------------------------
   4. Verify projection metadata
   ------------------------------------------------------------ */

SELECT
    database,
    table,
    name,
    type,
    sorting_key
FROM system.projections
WHERE database = 'analytics'
  AND table = 'events';


/* ------------------------------------------------------------
   5. Benchmark the base table
   ------------------------------------------------------------ */

SET optimize_use_projections = 0;
SET force_optimize_projection = 0;
SET log_comment = 'covering_projection_disabled';

SELECT
    count() AS total_events,
    min(event_time) AS first_event,
    max(event_time) AS last_event,
    round(sum(toFloat64(revenue)), 2) AS total_revenue
FROM analytics.events
WHERE user_id = 73035;


/* ------------------------------------------------------------
   6. Inspect the optimized query plan

   force_optimize_projection makes the test deterministic:
   ClickHouse will return an error if no suitable projection
   can be applied.
   ------------------------------------------------------------ */

SET optimize_use_projections = 1;
SET force_optimize_projection = 1;

EXPLAIN projections = 1
SELECT
    count() AS total_events,
    min(event_time) AS first_event,
    max(event_time) AS last_event,
    round(sum(toFloat64(revenue)), 2) AS total_revenue
FROM analytics.events
WHERE user_id = 73035;


/* ------------------------------------------------------------
   7. Execute the query using the projection
   ------------------------------------------------------------ */

SET log_comment = 'covering_projection_enabled';

SELECT
    count() AS total_events,
    min(event_time) AS first_event,
    max(event_time) AS last_event,
    round(sum(toFloat64(revenue)), 2) AS total_revenue
FROM analytics.events
WHERE user_id = 73035;


/* Disable enforcement before querying system tables */

SET force_optimize_projection = 0;
SET log_comment = '';

SYSTEM FLUSH LOGS;


/* ------------------------------------------------------------
   8. Compare benchmark results
   ------------------------------------------------------------ */

SELECT
    log_comment AS benchmark,
    query_duration_ms,
    read_rows,
    formatReadableSize(read_bytes) AS data_read,
    formatReadableSize(memory_usage) AS memory_used,
    projections
FROM system.query_log
WHERE type = 'QueryFinish'
  AND log_comment IN
  (
      'covering_projection_disabled',
      'covering_projection_enabled'
  )
  AND position(query, 'FROM analytics.events') > 0
ORDER BY event_time DESC
LIMIT 1 BY log_comment;


/* ------------------------------------------------------------
   9. Show projection storage usage
   ------------------------------------------------------------ */

SELECT
    name AS part_name,
    rows,
    formatReadableSize(bytes_on_disk) AS projection_size
FROM system.projection_parts
WHERE database = 'analytics'
  AND table = 'events'
  AND name = 'prj_user_lookup'
  AND active
ORDER BY part_name;


/* ------------------------------------------------------------
   10. Reset session settings
   ------------------------------------------------------------ */

SET optimize_use_projections = 1;
SET force_optimize_projection = 0;
SET log_comment = '';