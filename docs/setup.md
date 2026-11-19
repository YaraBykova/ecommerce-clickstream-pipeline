# Запуск и тесты

Понадобятся Python 3.10 или новее, Docker Compose и SQL-клиент для просмотра
результатов. Команды приведены для Windows PowerShell и выполняются из корня проекта.

## Подготовка

Скачайте набор со [страницы источника](https://www.kaggle.com/datasets/mkechinov/ecommerce-events-history-in-electronics-store)
и поместите архив в `data/events.csv.zip`. В ZIP должен быть один CSV с полями
в указанном порядке:

```text
event_time,event_type,product_id,category_id,category_code,brand,price,user_id,user_session
```

Пример времени события — `2020-09-24 11:57:06 UTC`. Загрузчик также принимает
отдельный CSV с той же структурой.

Создайте в корне проекта `.env` и задайте локальный пароль:

```dotenv
POSTGRES_HOST=localhost
POSTGRES_PORT=5433
POSTGRES_DB=electronics_events
POSTGRES_USER=electronics_user
POSTGRES_PASSWORD=replace_with_your_local_password
```

Настройки, исходные данные и виртуальное окружение исключены из Git.

## Первый запуск

Запустите Docker Desktop. Следующие команды создают окружение Python
и запускают PostgreSQL из `compose.yaml`:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
docker compose up -d
docker compose ps
```

Дождитесь статуса `healthy`. Затем загрузите архив:

```powershell
.\.venv\Scripts\python.exe scripts/run_pipeline.py --source data/events.csv.zip
```

Команда создаёт схему и витрины при первом запуске, регистрирует партию,
загружает исходные события и пересчитывает сессии. Повтор команды даёт 0 новых строк.

Постройте графики:

```powershell
.\.venv\Scripts\python.exe scripts/plot_results.py
```

Изображения сохраняются в `docs/images/`. После обновления данных повторите
построение графиков.

## Результаты в базе

Подключитесь через SQL-клиент к базе из `.env`, используя указанные там
порт, имя пользователя и пароль. Основные запросы:

```sql
SELECT * FROM mart.funnel_summary;

SELECT *
FROM mart.category_conversion
ORDER BY sessions_without_cart DESC, category_code;

SELECT * FROM mart.category_data_quality;

SELECT * FROM raw.import_batches ORDER BY registered_at;
```

## Загрузка отдельных партий

Для файла с постоянным ID доставки:

```powershell
.\.venv\Scripts\python.exe scripts/run_pipeline.py --source data/new-events.csv --batch-id delivery-001
```

По умолчанию ID формируется из содержимого. Правила повторов описаны
в [методике](methodology.md#идентичность-доставки).

Для другой базы передайте её настройки через `--env-file путь-к-файлу`.

## Проверка загрузки по частям

Для нарезки архива используйте отдельную пустую базу. Полный архив и его части
представляют один набор событий, поэтому для сравнения они загружаются отдельно.

Создайте базу в SQL-клиенте:

```sql
CREATE DATABASE electronics_batches;
```

Скопируйте настройки и измените в новом файле базу на `electronics_batches`:

```powershell
Copy-Item .env data/batches.env
```

Подготовьте партии по 100 000 строк:

```powershell
.\.venv\Scripts\python.exe scripts/split_source.py
```

Каталог `data/batches/` появляется после успешной проверки всего источника.
Другой каталог задаётся через `--output-dir`, размер партии — через
`--rows-per-batch`. Если каталог уже существует, используйте подготовленные
партии или задайте новый путь.

Загрузите файлы по порядку:

```powershell
Get-ChildItem data/batches/batch-*.csv | Sort-Object Name | ForEach-Object {
    .\.venv\Scripts\python.exe scripts/run_pipeline.py --source $_.FullName --env-file data/batches.env
    if ($LASTEXITCODE -ne 0) { throw "Загрузка партии завершилась ошибкой" }
}
```

Повторите цикл для проверки повторной доставки.

## Обновление прежней загрузки

Если raw заполнен старым загрузчиком, передайте `run_pipeline.py` полный
исходный архив. После сверки всех записей в исходном порядке загрузчик
зарегистрирует прежние строки с сохранением `raw_event_id`.
Несовпадение приводит к ошибке и откату.

Для работы только с исходным слоем доступен `scripts/load_raw.py` с теми же
аргументами. Следующий запуск `run_pipeline.py` обработает ожидающие партии.

## Тесты и контрольные запросы

Интеграционные тесты создают отдельные временные базы. Задайте подключение
к PostgreSQL с правом `CREATE DATABASE` и своим локальным паролем:

```powershell
$env:TEST_DATABASE_URL = "host=localhost port=5433 dbname=postgres user=electronics_user password=replace_with_your_local_password"
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

Проверки SQL выполняются целиком в выбранной базе:

- `sql/03_quality_checks.sql` — баланс событий и согласованность сессий.
- `sql/05_check_marts.sql` — полнота воронки и порядок действий.
- `sql/07_check_category_conversion.sql` — категории и покрытие данных.

Счётчики несоответствий должны быть равны нулю. Эти SQL-файлы возвращают
результаты для просмотра. Интеграционные тесты завершаются ошибкой при нарушении проверки.

`sql/02_build_core.sql` выполняет полную пересборку из raw.
Миграцию `08_enable_batches.sql` загрузчик применяет автоматически.
`09_refresh_sessions.sql` вызывается им в транзакции для затронутых сессий.

## Остановка

```powershell
docker compose stop
```

После остановки сервисов проекта Docker Desktop можно закрыть через системный трей.

[К описанию проекта](../README.md) · [Результаты проверки](../reports/batch-processing.md)
