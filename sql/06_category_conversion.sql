-- Переход от просмотра к корзине по заполненному category_code.
-- Подготовлено агентом; учебный черновик для совместного разбора.
-- Одна строка mart.session_category_funnel = одна пара сессия + категория
-- с хотя бы одним просмотром. Товар просмотра и товар корзины могут различаться.
-- Разные category_id с одинаковым category_code объединяются внутри сессии.
-- События без названия категории учитываются отдельно в category_data_quality.

BEGIN;

DROP VIEW IF EXISTS mart.category_conversion;
DROP VIEW IF EXISTS mart.session_category_funnel;
DROP VIEW IF EXISTS mart.category_data_quality;

CREATE VIEW mart.session_category_funnel AS
WITH first_views AS (
    SELECT
        session_id,
        BTRIM(category_code) AS category_code,
        MIN(event_time) AS view_at
    FROM core.events
    WHERE event_type = 'view'
      AND NULLIF(BTRIM(category_code), '') IS NOT NULL
    GROUP BY session_id, BTRIM(category_code)
)
SELECT
    first_view.session_id,
    first_view.category_code,
    first_view.view_at,
    MIN(cart.event_time) AS cart_at
FROM first_views AS first_view
LEFT JOIN core.events AS cart
    ON cart.session_id = first_view.session_id
   AND BTRIM(cart.category_code) = first_view.category_code
   AND cart.event_type = 'cart'
   AND cart.event_time > first_view.view_at
GROUP BY
    first_view.session_id,
    first_view.category_code,
    first_view.view_at;

CREATE VIEW mart.category_conversion AS
SELECT
    category_code,
    COUNT(*) AS view_sessions,
    COUNT(cart_at) AS cart_sessions,
    COUNT(*) - COUNT(cart_at) AS sessions_without_cart,
    COUNT(cart_at)::NUMERIC / NULLIF(COUNT(*), 0)
        AS view_to_cart_conversion
FROM mart.session_category_funnel
GROUP BY category_code;

CREATE VIEW mart.category_data_quality AS
SELECT
    COUNT(*) AS total_events,
    COUNT(*) FILTER (
        WHERE NULLIF(BTRIM(category_code), '') IS NOT NULL
    ) AS named_category_events,
    COUNT(*) FILTER (
        WHERE NULLIF(BTRIM(category_code), '') IS NULL
    ) AS unnamed_category_events,
    COUNT(*) FILTER (
        WHERE NULLIF(BTRIM(category_code), '') IS NULL
    )::NUMERIC / NULLIF(COUNT(*), 0) AS unnamed_category_share
FROM core.events;

COMMIT;

-- Первые десять категорий по числу сессий без последующей корзины.
-- Порог 1000 просмотровых сессий ограничивает таблицу крупными группами.
SELECT
    category_code,
    view_sessions,
    cart_sessions,
    sessions_without_cart,
    ROUND(100 * view_to_cart_conversion, 2) AS conversion_percent
FROM mart.category_conversion
WHERE view_sessions >= 1000
ORDER BY sessions_without_cart DESC, category_code
LIMIT 10;

-- Кандидаты для дальнейшей проверки: крупные группы с конверсией
-- ниже общей доли переходов по парам сессия + категория.
-- Сортировка по объёму сессий без корзины определяет приоритет просмотра.
WITH baseline AS (
    SELECT
        SUM(cart_sessions)::NUMERIC / NULLIF(SUM(view_sessions), 0)
            AS conversion
    FROM mart.category_conversion
)
SELECT
    category.category_code,
    category.view_sessions,
    category.cart_sessions,
    category.sessions_without_cart,
    ROUND(100 * category.view_to_cart_conversion, 2) AS conversion_percent,
    ROUND(100 * baseline.conversion, 2) AS baseline_percent
FROM mart.category_conversion AS category
CROSS JOIN baseline
WHERE category.view_sessions >= 1000
  AND category.view_to_cart_conversion < baseline.conversion
ORDER BY category.sessions_without_cart DESC, category.category_code
LIMIT 5;

-- Покрытие анализа по событиям core. События с неизвестной категорией
-- остаются доступными в core и участвуют в общей воронке магазина.
SELECT * FROM mart.category_data_quality;
