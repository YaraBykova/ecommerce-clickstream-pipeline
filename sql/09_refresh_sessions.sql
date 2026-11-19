-- Пересчёт сессий новой партии. Подготовлено агентом для совместного разбора.
-- Вызывается из load_batch в общей транзакции с загрузкой raw.
-- batch_affected_sessions содержит только сессии зарегистрированной партии.

DROP TABLE IF EXISTS pg_temp.batch_affected_users;
DROP TABLE IF EXISTS pg_temp.batch_affected_products;
DROP TABLE IF EXISTS pg_temp.batch_valid_sessions;

CREATE TEMP TABLE batch_affected_users ON COMMIT DROP AS
SELECT event.user_id
FROM core.events AS event
JOIN batch_affected_sessions AS affected USING (session_id)
UNION
SELECT event.user_id
FROM raw.events_import AS event
JOIN batch_affected_sessions AS affected
    ON affected.session_id = event.user_session;

CREATE TEMP TABLE batch_affected_products ON COMMIT DROP AS
SELECT event.product_id
FROM core.events AS event
JOIN batch_affected_sessions AS affected USING (session_id)
UNION
SELECT event.product_id
FROM raw.events_import AS event
JOIN batch_affected_sessions AS affected
    ON affected.session_id = event.user_session;

DELETE FROM core.events AS event
USING batch_affected_sessions AS affected
WHERE event.session_id = affected.session_id;

DELETE FROM core.sessions AS session
USING batch_affected_sessions AS affected
WHERE session.session_id = affected.session_id;

CREATE TEMP TABLE batch_valid_sessions ON COMMIT DROP AS
SELECT
    event.user_session AS session_id,
    MIN(event.user_id) AS user_id,
    MIN(event.event_time) AS started_at,
    MAX(event.event_time) AS ended_at,
    COUNT(*)::INTEGER AS event_count
FROM raw.events_import AS event
JOIN batch_affected_sessions AS affected
    ON affected.session_id = event.user_session
GROUP BY event.user_session
HAVING COUNT(DISTINCT event.user_id) = 1
   AND MAX(event.event_time) - MIN(event.event_time) <= INTERVAL '24 hours';

INSERT INTO core.users (user_id, first_seen_at, last_seen_at)
SELECT event.user_id, MIN(event.event_time), MAX(event.event_time)
FROM raw.events_import AS event
JOIN batch_valid_sessions AS session ON session.session_id = event.user_session
GROUP BY event.user_id
ON CONFLICT (user_id) DO NOTHING;

INSERT INTO core.products (product_id, first_seen_at, last_seen_at)
SELECT event.product_id, MIN(event.event_time), MAX(event.event_time)
FROM raw.events_import AS event
JOIN batch_valid_sessions AS session ON session.session_id = event.user_session
GROUP BY event.product_id
ON CONFLICT (product_id) DO NOTHING;

INSERT INTO core.sessions (session_id, user_id, started_at, ended_at, event_count)
SELECT session_id, user_id, started_at, ended_at, event_count
FROM batch_valid_sessions;

INSERT INTO core.events (
    raw_event_id, event_time, event_type, user_id, session_id,
    product_id, category_id, category_code, brand, price
)
SELECT
    event.raw_event_id, event.event_time, event.event_type, event.user_id,
    session.session_id, event.product_id, event.category_id,
    event.category_code, event.brand, event.price
FROM raw.events_import AS event
JOIN batch_valid_sessions AS session ON session.session_id = event.user_session;

-- Позднее событие может сделать прежнюю сессию некорректной.
-- Границы пользователя и товара рассчитываются по оставшимся событиям core.
UPDATE core.users AS user_record
SET first_seen_at = actual.first_seen_at, last_seen_at = actual.last_seen_at
FROM (
    SELECT event.user_id,
        MIN(event.event_time) AS first_seen_at,
        MAX(event.event_time) AS last_seen_at
    FROM core.events AS event
    JOIN batch_affected_users AS affected USING (user_id)
    GROUP BY event.user_id
) AS actual
WHERE user_record.user_id = actual.user_id;

UPDATE core.products AS product
SET first_seen_at = actual.first_seen_at, last_seen_at = actual.last_seen_at
FROM (
    SELECT event.product_id,
        MIN(event.event_time) AS first_seen_at,
        MAX(event.event_time) AS last_seen_at
    FROM core.events AS event
    JOIN batch_affected_products AS affected USING (product_id)
    GROUP BY event.product_id
) AS actual
WHERE product.product_id = actual.product_id;

DELETE FROM core.users AS user_record
USING batch_affected_users AS affected
WHERE user_record.user_id = affected.user_id
  AND NOT EXISTS (SELECT 1 FROM core.sessions WHERE user_id = user_record.user_id);

DELETE FROM core.products AS product
USING batch_affected_products AS affected
WHERE product.product_id = affected.product_id
  AND NOT EXISTS (SELECT 1 FROM core.events WHERE product_id = product.product_id);
