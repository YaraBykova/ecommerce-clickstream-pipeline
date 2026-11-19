-- Все счётчики несоответствий должны быть равны 0.
-- Подготовлено агентом; учебный черновик для совместного разбора.
WITH actual_funnel AS MATERIALIZED (
    SELECT * FROM mart.session_category_funnel
),
event_views AS (
    SELECT
        session_id,
        category_id,
        event_type,
        event_time,
        MIN(event_time) FILTER (WHERE event_type = 'view') OVER (
            PARTITION BY session_id, category_id
        ) AS view_at
    FROM core.events
),
expected_funnel AS (
    SELECT
        session_id,
        category_id,
        MIN(view_at) AS view_at,
        MIN(event_time) FILTER (
            WHERE event_type = 'cart' AND event_time > view_at
        ) AS cart_at
    FROM event_views
    GROUP BY session_id, category_id
    HAVING MIN(view_at) IS NOT NULL
)
SELECT
    COUNT(*) FILTER (
        WHERE actual.session_id IS NULL
    ) AS missing_pairs,
    COUNT(*) FILTER (
        WHERE expected.session_id IS NULL
    ) AS extra_pairs,
    COUNT(*) FILTER (
        WHERE actual.view_at IS DISTINCT FROM expected.view_at
    ) AS view_mismatches,
    COUNT(*) FILTER (
        WHERE actual.cart_at IS DISTINCT FROM expected.cart_at
    ) AS cart_mismatches,
    COUNT(*) FILTER (
        WHERE actual.cart_at <= actual.view_at
    ) AS invalid_event_order,
    (
        SELECT COUNT(*)
        FROM (
            SELECT session_id, category_id
            FROM actual_funnel
            GROUP BY session_id, category_id
            HAVING COUNT(*) > 1
        ) AS duplicates
    ) AS duplicate_pairs,
    (
        SELECT COUNT(*)
        FROM mart.category_conversion
        WHERE cart_sessions > view_sessions
           OR cart_sessions + sessions_without_cart <> view_sessions
    ) AS invalid_counts
FROM expected_funnel AS expected
FULL JOIN actual_funnel AS actual
    USING (session_id, category_id);

-- Несколько непустых названий одного ID требуют проверки источника.
SELECT COUNT(*) AS category_ids_with_multiple_codes
FROM (
    SELECT category_id
    FROM core.events
    GROUP BY category_id
    HAVING COUNT(DISTINCT NULLIF(BTRIM(category_code), '')) > 1
) AS ambiguous_categories;
