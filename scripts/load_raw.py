"""Загружает clickstream-события из ZIP в сырой слой PostgreSQL."""

import csv
import io
import zipfile
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

import psycopg


PROJECT_DIR = Path(__file__).resolve().parent.parent
ARCHIVE_PATH = PROJECT_DIR / "data" / "events.csv.zip"
ENV_PATH = PROJECT_DIR / ".env"

EXPECTED_COLUMNS = (
    "event_time",
    "event_type",
    "product_id",
    "category_id",
    "category_code",
    "brand",
    "price",
    "user_id",
    "user_session",
)

REQUIRED_COLUMNS = (
    "event_time",
    "event_type",
    "product_id",
    "category_id",
    "price",
    "user_id",
)

COPY_SQL = """
    COPY raw.events_import (
        source_file_name,
        event_time,
        event_type,
        product_id,
        category_id,
        category_code,
        brand,
        price,
        user_id,
        user_session
    ) FROM STDIN
"""


def read_settings():
    """Читает параметры подключения из локального файла .env."""
    if not ENV_PATH.is_file():
        raise FileNotFoundError(f"Не найден файл настроек: {ENV_PATH}")

    settings = {}
    for line_number, line in enumerate(
        ENV_PATH.read_text(encoding="utf-8").splitlines(), start=1
    ):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"Некорректная строка {line_number} в {ENV_PATH.name}")

        key, value = line.split("=", 1)
        settings[key.strip()] = value.strip()

    required_settings = (
        "POSTGRES_DB",
        "POSTGRES_USER",
        "POSTGRES_PASSWORD",
        "POSTGRES_PORT",
    )
    missing_settings = [
        name for name in required_settings if not settings.get(name)
    ]
    if missing_settings:
        raise ValueError("В .env не заданы: " + ", ".join(missing_settings))

    return settings


def empty_to_none(value):
    """Преобразует пустое необязательное поле в SQL NULL."""
    value = value.strip()
    return value if value else None


def prepare_row(row, source_file_name, line_number):
    """Проверяет одну CSV-строку и готовит её для PostgreSQL."""
    for column in REQUIRED_COLUMNS:
        if not row[column].strip():
            raise ValueError(
                f"Строка CSV {line_number}: пустое обязательное поле {column!r}"
            )

    try:
        event_time = datetime.strptime(
            row["event_time"].strip(), "%Y-%m-%d %H:%M:%S UTC"
        ).replace(tzinfo=timezone.utc)
        product_id = int(row["product_id"].strip())
        category_id = int(row["category_id"].strip())
        price = Decimal(row["price"].strip())
        user_id = int(row["user_id"].strip())
    except (ValueError, InvalidOperation) as error:
        raise ValueError(
            f"Строка CSV {line_number}: не удалось преобразовать типы данных"
        ) from error

    if price.as_tuple().exponent < -2:
        raise ValueError(
            f"Строка CSV {line_number}: у цены больше двух знаков после запятой"
        )

    return (
        source_file_name,
        event_time,
        row["event_type"].strip(),
        product_id,
        category_id,
        empty_to_none(row["category_code"]),
        empty_to_none(row["brand"]),
        price,
        user_id,
        empty_to_none(row["user_session"]),
    )


def iter_source_rows():
    """Читает CSV из ZIP по одной строке, не загружая весь файл в память."""
    if not ARCHIVE_PATH.is_file():
        raise FileNotFoundError(f"Не найден ZIP-источник: {ARCHIVE_PATH}")

    with zipfile.ZipFile(ARCHIVE_PATH) as archive:
        csv_files = [
            item for item in archive.infolist() if item.filename.endswith(".csv")
        ]
        if len(csv_files) != 1:
            raise ValueError(
                "В ZIP должен быть ровно один CSV-файл. "
                f"Найдено: {len(csv_files)}"
            )

        with archive.open(csv_files[0]) as binary_file:
            text_file = io.TextIOWrapper(
                binary_file, encoding="utf-8-sig", newline=""
            )
            reader = csv.DictReader(text_file)

            if tuple(reader.fieldnames or ()) != EXPECTED_COLUMNS:
                raise ValueError("Структура CSV не совпадает с ожидаемой")

            for line_number, row in enumerate(reader, start=2):
                yield prepare_row(row, ARCHIVE_PATH.name, line_number)


def load_raw():
    """Загружает источник в raw.events_import одной транзакцией."""
    settings = read_settings()

    with psycopg.connect(
        host=settings.get("POSTGRES_HOST", "localhost"),
        port=int(settings["POSTGRES_PORT"]),
        dbname=settings["POSTGRES_DB"],
        user=settings["POSTGRES_USER"],
        password=settings["POSTGRES_PASSWORD"],
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT EXISTS (SELECT 1 FROM raw.events_import)")
            if cursor.fetchone()[0]:
                raise RuntimeError(
                    "raw.events_import уже содержит данные. "
                    "Повторная загрузка отменена."
                )

            loaded_rows = 0
            with cursor.copy(COPY_SQL) as copy:
                for loaded_rows, row in enumerate(iter_source_rows(), start=1):
                    copy.write_row(row)
                    if loaded_rows % 100_000 == 0:
                        print(f"Подготовлено к загрузке: {loaded_rows:,} строк")

    return loaded_rows


def main():
    loaded_rows = load_raw()
    print(f"Готово: в raw.events_import загружено {loaded_rows:,} строк")


if __name__ == "__main__":
    main()
