-- Переход от просмотра к корзине внутри одной категории.
-- Подготовлено агентом; учебный черновик для совместного разбора.
-- Одна строка mart.session_category_funnel = одна пара сессия + категория
-- с хотя бы одним просмотром. Товар просмотра и товар корзины могут различаться.

BEGIN;

DROP VIEW IF EXISTS mart.category_conversion;
DROP VIEW IF EXISTS mart.session_category_funnel;

CREATE VIEW mart.session_category_funnel AS
WITH first_views AS (
    SELECT
        session_id,
        category_id,
        MIN(NULLIF(BTRIM(category_code), '')) AS category_code,
        MIN(event_time) AS view_at
    FROM core.events
    WHERE event_type = 'view'
    GROUP BY session_id, category_id
)
SELECT
    first_view.session_id,
    first_view.category_id,
    first_view.category_code,
    first_view.view_at,
    MIN(cart.event_time) AS cart_at
FROM first_views AS first_view
LEFT JOIN core.events AS cart
    ON cart.session_id = first_view.session_id
   AND cart.category_id = first_view.category_id
   AND cart.event_type = 'cart'
   AND cart.event_time > first_view.view_at
GROUP BY
    first_view.session_id,
    first_view.category_id,
    first_view.category_code,
    first_view.view_at;

CREATE VIEW mart.category_conversion AS
SELECT
    category_id,
    MIN(category_code) AS category_code,
    COUNT(*) AS view_sessions,
    COUNT(cart_at) AS cart_sessions,
    COUNT(*) - COUNT(cart_at) AS sessions_without_cart,
    COUNT(cart_at)::NUMERIC / NULLIF(COUNT(*), 0)
        AS view_to_cart_conversion
FROM mart.session_category_funnel
GROUP BY category_id;

COMMIT;

-- Первые десять категорий по числу сессий без последующей корзины.
-- Порог 1000 просмотровых сессий ограничивает таблицу крупными группами.
SELECT
    category_id,
    category_code,
    view_sessions,
    cart_sessions,
    sessions_without_cart,
    ROUND(100 * view_to_cart_conversion, 2) AS conversion_percent
FROM mart.category_conversion
WHERE view_sessions >= 1000
ORDER BY sessions_without_cart DESC, category_id
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
    category.category_id,
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
ORDER BY category.sessions_without_cart DESC, category.category_id
LIMIT 5;
