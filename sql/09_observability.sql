/* ============================================================
   Step 09 — ClickHouse Observability and Operational Monitoring

   Covers:
   - Server health
   - Disk utilization
   - Table and partition storage
   - Data-part health
   - Running queries
   - Background merges
   - Mutations
   - Query performance
   - Failed queries
   - Repeated query patterns
   - Runtime metrics
   ============================================================ */


/* ------------------------------------------------------------
   1. Server information
   ------------------------------------------------------------ */

SELECT
    version() AS clickhouse_version,
    hostName() AS host_name,
    timezone() AS server_timezone,
    uptime() AS uptime_seconds,
    formatReadableTimeDelta(uptime()) AS readable_uptime;


/* ------------------------------------------------------------
   2. Disk capacity and utilization
   ------------------------------------------------------------ */

SELECT
    name AS disk_name,
    path,

    formatReadableSize(total_space)
        AS readable_total_space,

    formatReadableSize(free_space)
        AS readable_free_space,

    formatReadableSize(total_space - free_space)
        AS readable_used_space,

    round(
        100.0 * (total_space - free_space)
            / nullIf(total_space, 0),
        2
    ) AS used_percent,

    formatReadableSize(keep_free_space)
        AS readable_reserved_space

FROM system.disks
ORDER BY name;

/* ------------------------------------------------------------
   3. Storage summary for analytics tables
   ------------------------------------------------------------ */

SELECT
    database,
    table,
    uniqExact(partition) AS partitions,
    count() AS active_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    formatReadableSize(sum(data_compressed_bytes))
        AS compressed_data,
    formatReadableSize(sum(data_uncompressed_bytes))
        AS uncompressed_data,
    round(
        sum(data_uncompressed_bytes)
            / nullIf(sum(data_compressed_bytes), 0),
        2
    ) AS compression_ratio
FROM system.parts
WHERE database = 'analytics'
  AND active
GROUP BY
    database,
    table
ORDER BY sum(bytes_on_disk) DESC;


/* ------------------------------------------------------------
   4. Partition-level storage overview
   ------------------------------------------------------------ */

SELECT
    table,
    partition,
    count() AS active_parts,
    sum(rows) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    min(min_time) AS minimum_event_time,
    max(max_time) AS maximum_event_time,
    max(modification_time) AS last_modified
FROM system.parts
WHERE database = 'analytics'
  AND active
GROUP BY
    table,
    partition
ORDER BY
    table,
    partition;


/* ------------------------------------------------------------
   5. Data-part health
   A large number of small parts may reduce performance.
   ------------------------------------------------------------ */

SELECT
    table,
    count() AS active_parts,
    countIf(rows < 10000) AS small_parts,
    round(
        100 * countIf(rows < 10000)
            / nullIf(count(), 0),
        2
    ) AS small_parts_percent,
    formatReadableQuantity(sum(rows)) AS total_rows,
    formatReadableSize(sum(bytes_on_disk)) AS disk_size,
    max(modification_time) AS newest_part,
    multiIf(
        count() >= 300, 'CRITICAL: too many active parts',
        count() >= 100, 'WARNING: monitor part count',
        countIf(rows < 10000) >= 50, 'WARNING: many small parts',
        'OK'
    ) AS health_status
FROM system.parts
WHERE database = 'analytics'
  AND active
GROUP BY table
ORDER BY active_parts DESC;


/* ------------------------------------------------------------
   6. Currently running queries
   This query itself is excluded from the result.
   ------------------------------------------------------------ */

SELECT
    user,
    query_id,
    round(elapsed, 3) AS elapsed_seconds,
    formatReadableQuantity(read_rows) AS rows_read,
    formatReadableSize(read_bytes) AS data_read,
    formatReadableSize(memory_usage) AS memory_used,
    left(replaceRegexpAll(query, '\\s+', ' '), 160)
        AS running_query
FROM system.processes
WHERE query NOT ILIKE '%system.processes%'
ORDER BY elapsed DESC;


/* ------------------------------------------------------------
   7. Active background merges and mutations
   An empty result means no merge is currently running.
   ------------------------------------------------------------ */

SELECT
    database,
    table,
    round(elapsed, 2) AS elapsed_seconds,
    round(progress * 100, 2) AS progress_percent,
    num_parts AS source_parts,
    is_mutation,
    result_part_name,
    formatReadableSize(total_size_bytes_compressed)
        AS source_size,
    formatReadableSize(memory_usage) AS memory_used
FROM system.merges
WHERE database = 'analytics'
ORDER BY elapsed DESC;


/* ------------------------------------------------------------
   8. Pending or failed mutations
   An empty result is normally a healthy result.
   ------------------------------------------------------------ */

SELECT
    database,
    table,
    mutation_id,
    command,
    create_time,
    parts_to_do,
    is_done,
    latest_failed_part,
    latest_fail_time,
    left(latest_fail_reason, 200) AS failure_reason
FROM system.mutations
WHERE database = 'analytics'
  AND is_done = 0
ORDER BY create_time;


/* ------------------------------------------------------------
   9. Generate two observable benchmark queries
   Query A scans the complete skip-index demo table.
   Query B uses the data-skipping index.
   ------------------------------------------------------------ */

SET log_comment = 'observability_full_scan';

SELECT
    count() AS matching_rows,
    round(avg(response_time_ms), 2) AS average_response_time
FROM analytics.skip_index_demo
WHERE status_code = 500
SETTINGS use_skip_indexes = 0;


SET log_comment = 'observability_indexed_query';

SELECT
    count() AS matching_rows,
    round(avg(response_time_ms), 2) AS average_response_time
FROM analytics.skip_index_demo
WHERE status_code = 500
SETTINGS force_data_skipping_indices = 'idx_status_code';


SET log_comment = '';

SYSTEM FLUSH LOGS;


/* ------------------------------------------------------------
   10. Compare the tagged benchmark queries
   ------------------------------------------------------------ */

SELECT
    log_comment AS benchmark,
    query_duration_ms,
    read_rows,
    formatReadableQuantity(read_rows) AS readable_rows,
    formatReadableSize(read_bytes) AS data_read,
    formatReadableSize(memory_usage) AS memory_used,
    projections,
    left(replaceRegexpAll(query, '\\s+', ' '), 140)
        AS executed_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND is_initial_query = 1
  AND log_comment IN
  (
      'observability_full_scan',
      'observability_indexed_query'
  )
ORDER BY event_time DESC
LIMIT 1 BY log_comment;


/* ------------------------------------------------------------
   11. Read-row reduction from the skipping index
   ------------------------------------------------------------ */

WITH
    (
        SELECT read_rows
        FROM system.query_log
        WHERE type = 'QueryFinish'
          AND is_initial_query = 1
          AND log_comment = 'observability_full_scan'
        ORDER BY event_time DESC
        LIMIT 1
    ) AS full_scan_rows,

    (
        SELECT read_rows
        FROM system.query_log
        WHERE type = 'QueryFinish'
          AND is_initial_query = 1
          AND log_comment = 'observability_indexed_query'
        ORDER BY event_time DESC
        LIMIT 1
    ) AS indexed_rows

SELECT
    full_scan_rows,
    indexed_rows,
    round(
        100 * (full_scan_rows - indexed_rows)
            / nullIf(full_scan_rows, 0),
        2
    ) AS read_row_reduction_percent;


/* ------------------------------------------------------------
   12. Most expensive successful queries in the last 24 hours
   ------------------------------------------------------------ */

SELECT
    event_time,
    user,
    query_duration_ms,
    formatReadableQuantity(read_rows) AS rows_read,
    formatReadableSize(read_bytes) AS data_read,
    formatReadableSize(memory_usage) AS memory_used,
    query_kind,
    left(replaceRegexpAll(query, '\\s+', ' '), 160)
        AS executed_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND is_initial_query = 1
  AND event_time >= now() - INTERVAL 24 HOUR
  AND query NOT ILIKE '%system.query_log%'
ORDER BY query_duration_ms DESC
LIMIT 10;


/* ------------------------------------------------------------
   13. Recent failed queries
   Previous intentional errors may also appear here.
   ------------------------------------------------------------ */

SELECT
    event_time,
    user,
    query_id,
    exception_code,
    left(exception, 180) AS exception_message,
    left(replaceRegexpAll(query, '\\s+', ' '), 160)
        AS failed_query
FROM system.query_log
WHERE type IN
(
    'ExceptionBeforeStart',
    'ExceptionWhileProcessing'
)
  AND is_initial_query = 1
  AND event_time >= now() - INTERVAL 24 HOUR
ORDER BY event_time DESC
LIMIT 10;


/* ------------------------------------------------------------
   14. Repeated query patterns
   normalized_query_hash groups structurally similar queries.
   ------------------------------------------------------------ */

SELECT
    normalized_query_hash,
    count() AS executions,
    round(avg(query_duration_ms), 2)
        AS average_duration_ms,
    max(query_duration_ms) AS maximum_duration_ms,
    formatReadableQuantity(sum(read_rows))
        AS total_rows_read,
    formatReadableSize(sum(read_bytes))
        AS total_data_read,
    formatReadableSize(max(memory_usage))
        AS maximum_memory,
    left(
        replaceRegexpAll(any(query), '\\s+', ' '),
        160
    ) AS sample_query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND is_initial_query = 1
  AND event_time >= now() - INTERVAL 24 HOUR
  AND query NOT ILIKE '%system.query_log%'
GROUP BY normalized_query_hash
ORDER BY total_rows_read DESC
LIMIT 10;


/* ------------------------------------------------------------
   15. Selected real-time ClickHouse metrics
   ------------------------------------------------------------ */

SELECT
    metric,
    value,
    description
FROM system.metrics
WHERE metric IN
(
    'Query',
    'Merge',
    'PartMutation',
    'MemoryTracking',
    'TCPConnection',
    'BackgroundMergesAndMutationsPoolTask'
)
ORDER BY metric;


/* ------------------------------------------------------------
   16. Final compact health report
   ------------------------------------------------------------ */

SELECT
    now() AS checked_at,

    (
        SELECT count()
        FROM system.processes
    ) AS running_queries,

    (
        SELECT count()
        FROM system.merges
        WHERE database = 'analytics'
    ) AS active_merges,

    (
        SELECT count()
        FROM system.mutations
        WHERE database = 'analytics'
          AND is_done = 0
    ) AS pending_mutations,

    (
        SELECT count()
        FROM system.parts
        WHERE database = 'analytics'
          AND active
    ) AS active_parts,

    (
        SELECT count()
        FROM system.query_log
        WHERE type IN
        (
            'ExceptionBeforeStart',
            'ExceptionWhileProcessing'
        )
          AND is_initial_query = 1
          AND event_time >= now() - INTERVAL 1 HOUR
    ) AS failed_queries_last_hour;