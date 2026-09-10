-- Создание слоёв raw, core и mart.
-- Выполняется один раз при первоначальной настройке базы.

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS mart;

-- Слой raw: типизированная копия строк из CSV.
-- Исходный ZIP хранится без изменений в data/events.csv.zip.
CREATE TABLE raw.events_import (
    raw_event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_file_name TEXT NOT NULL,
    event_time TIMESTAMPTZ NOT NULL,
    event_type TEXT NOT NULL,
    product_id BIGINT NOT NULL,
    category_id BIGINT NOT NULL,
    category_code TEXT,
    brand TEXT,
    price NUMERIC(12, 2) NOT NULL,
    user_id BIGINT NOT NULL,
    user_session TEXT,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Слой core: очищенные сущности, пригодные для аналитики.
CREATE TABLE core.users (
    user_id BIGINT PRIMARY KEY,
    first_seen_at TIMESTAMPTZ NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL,
    CHECK (first_seen_at <= last_seen_at)
);

-- В источнике нет устойчивого каталога с именами товаров.
-- Поэтому здесь храним идентификатор товара и период его появления,
-- а категорию, бренд и цену оставляем в событии как значения на момент действия.
CREATE TABLE core.products (
    product_id BIGINT PRIMARY KEY,
    first_seen_at TIMESTAMPTZ NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL,
    CHECK (first_seen_at <= last_seen_at)
);

-- В core попадают только сессии, прошедшие правила качества.
CREATE TABLE core.sessions (
    session_id TEXT PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES core.users(user_id),
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ NOT NULL,
    event_count INTEGER NOT NULL CHECK (event_count > 0),
    CHECK (started_at <= ended_at),
    CHECK (ended_at - started_at <= INTERVAL '24 hours'),
    UNIQUE (session_id, user_id)
);

-- Факт событий. Каждая строка связана с конкретной строкой raw-слоя:
-- так можно проследить происхождение аналитических данных.
CREATE TABLE core.events (
    raw_event_id BIGINT PRIMARY KEY
        REFERENCES raw.events_import(raw_event_id),
    event_time TIMESTAMPTZ NOT NULL,
    event_type TEXT NOT NULL CHECK (
        event_type IN ('view', 'cart', 'purchase')
    ),
    user_id BIGINT NOT NULL REFERENCES core.users(user_id),
    session_id TEXT NOT NULL,
    product_id BIGINT NOT NULL REFERENCES core.products(product_id),
    category_id BIGINT NOT NULL,
    category_code TEXT,
    brand TEXT,
    price NUMERIC(12, 2) NOT NULL CHECK (price >= 0),
    FOREIGN KEY (session_id, user_id)
        REFERENCES core.sessions(session_id, user_id)
);

-- Индексы под воронку, пути пользователя и когорты.
CREATE INDEX events_session_time_idx
    ON core.events (session_id, event_time);

CREATE INDEX events_user_time_idx
    ON core.events (user_id, event_time);

CREATE INDEX events_type_time_idx
    ON core.events (event_type, event_time);

-- В mart позже появятся витрины:
-- воронка по сессиям, путь до покупки и когорты/retention.
