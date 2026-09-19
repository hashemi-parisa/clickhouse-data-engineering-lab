INSERT INTO analytics.events
(
    event_time,
    user_id,
    event_type,
    platform,
    country_code,
    session_id,
    duration_ms,
    revenue,
    properties
)
SELECT
    now64(3, 'UTC') - toIntervalSecond(number % (90 * 86400)),
    1 + (number % 100000),
    arrayElement(
        ['page_view', 'search', 'add_to_cart', 'purchase', 'login'],
        1 + (number % 5)
    ),
    arrayElement(
        ['web', 'android', 'ios'],
        1 + (number % 3)
    ),
    arrayElement(
        ['CA', 'US', 'GB', 'DE', 'FR', 'AU'],
        1 + (number % 6)
    ),
    generateUUIDv4(),
    50 + (number % 5000),
    toDecimal64(
        if(number % 20 = 0, (number % 10000) / 100, 0),
        2
    ),
    concat(
        '{"campaign":"',
        arrayElement(
            ['organic', 'email', 'social', 'paid'],
            1 + (number % 4)
        ),
        '","synthetic":true}'
    )
FROM numbers(1000000);