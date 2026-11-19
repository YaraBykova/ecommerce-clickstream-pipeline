"""Строит графики README по витринам PostgreSQL. Черновик для совместного разбора."""

from decimal import Decimal

import matplotlib

matplotlib.use("Agg")

import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
import psycopg
from psycopg.rows import dict_row

from load_raw import PROJECT_DIR, read_settings


OUTPUT_DIR = PROJECT_DIR / "docs" / "images"
MIN_VIEW_SESSIONS = 1000
ACCENT = "#166B70"
SECONDARY = "#8299AE"
TEXT = "#192D40"
MUTED = "#526577"


def format_count(value):
    return f"{value:,.0f}".replace(",", " ")


def format_percent(value):
    if value is None:
        return "—"
    return f"{100 * value:.2f}%".replace(".", ",")


def plot_funnel(summary):
    counts = [summary["view_sessions"], summary["cart_sessions"], summary["purchase_sessions"]]
    labels = ["Просмотр", "Корзина после просмотра", "Покупка после корзины"]
    fig, axis = plt.subplots(figsize=(12, 5.4))
    fig.subplots_adjust(left=0.25, right=0.93, top=0.73, bottom=0.23)
    fig.text(0.04, 0.91, "Где прерывается путь к покупке", fontsize=22, weight="bold", color=TEXT)
    fig.text(0.04, 0.83, "Общая воронка магазина · каждая сессия учитывается один раз", fontsize=12, color=MUTED)

    axis.barh(labels, counts, color=["#436A8B", ACCENT, "#715986"], height=0.52)
    axis.invert_yaxis()
    axis.set_xlim(0, max(counts[0], 1) * 1.32)
    axis.set_xlabel("Количество сессий", color=MUTED, labelpad=10)
    axis.xaxis.set_major_formatter(FuncFormatter(lambda value, _: format_count(value)))
    axis.set_axisbelow(True)
    axis.grid(axis="x", color="#E5EAF0", linewidth=0.8)
    axis.tick_params(axis="both", length=0, labelsize=11)
    for spine in axis.spines.values():
        spine.set_visible(False)
    for index, count in enumerate(counts):
        share = count / counts[0] if counts[0] else 0
        axis.text(count + max(counts[0], 1) * 0.025, index,
                  f"{format_count(count)}  ·  {format_percent(share)}",
                  va="center", fontsize=12, weight="bold", color=TEXT)

    fig.text(0.04, 0.08,
             "Просмотр → корзина  " + format_percent(summary["view_to_cart_conversion"])
             + "     Корзина → покупка  " + format_percent(summary["cart_to_purchase_conversion"]),
             fontsize=12, color=TEXT)
    fig.text(0.04, 0.025, "Проценты рядом со столбцами рассчитаны от сессий с просмотром.",
             fontsize=10, color=MUTED)
    fig.savefig(OUTPUT_DIR / "session-funnel.png", dpi=160, facecolor="white")
    plt.close(fig)


def plot_categories(categories, coverage):
    total_views = sum(row["view_sessions"] for row in categories)
    total_carts = sum(row["cart_sessions"] for row in categories)
    baseline = Decimal(total_carts) / Decimal(total_views) if total_views else Decimal(0)
    baseline_percent = float(100 * baseline)
    candidates = [row for row in categories
                  if row["view_sessions"] >= MIN_VIEW_SESSIONS
                  and row["cart_sessions"] * total_views
                  < total_carts * row["view_sessions"]]
    candidates.sort(key=lambda row: (-row["sessions_without_cart"], row["category_code"]))
    candidates = candidates[:5]
    if not candidates:
        raise ValueError("Нет категорий, соответствующих правилу отбора для графика")

    names = {
        "electronics.telephone": "Телефоны",
        "electronics.video.tv": "Телевизоры",
        "stationery.cartrige": "Картриджи",
        "electronics.audio.acoustic": "Акустика",
        "computers.notebook": "Ноутбуки",
    }
    labels = [names.get(row["category_code"], row["category_code"]) for row in candidates]
    rates = [float(row["view_to_cart_conversion"]) * 100 for row in candidates]
    counts = [row["sessions_without_cart"] for row in candidates]
    positions = list(range(len(candidates)))
    colors = [ACCENT] + [SECONDARY] * (len(candidates) - 1)

    fig, (rate_axis, count_axis) = plt.subplots(
        1, 2, figsize=(12, 7.2), sharey=True, gridspec_kw={"width_ratios": [1, 1.15]}
    )
    fig.subplots_adjust(left=0.16, right=0.96, top=0.72, bottom=0.22, wspace=0.19)
    fig.text(0.035, 0.92, "Какие категории проверить в первую очередь", fontsize=22, weight="bold", color=TEXT)
    fig.text(0.035, 0.85, "Одинаковые названия объединены · одна пара «сессия + название категории» учитывается один раз",
             fontsize=12, color=MUTED)

    rate_axis.barh(positions, rates, color=colors, height=0.54)
    rate_axis.set_yticks(positions, labels, fontsize=12)
    rate_axis.invert_yaxis()
    rate_axis.set_xlim(0, max(baseline_percent, *rates) * 1.24)
    rate_axis.axvline(baseline_percent, color=TEXT, linestyle="--", linewidth=1.2)
    rate_axis.set_title("Дошли до корзины, %", loc="left", fontsize=12, pad=20, color=TEXT)
    rate_axis.xaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value:g}%"))
    count_axis.barh(positions, counts, color=colors, height=0.54)
    count_axis.set_xlim(0, max(counts) * 1.3)
    count_axis.set_title("Сессии без перехода\nк корзине", loc="left", fontsize=12, pad=20, color=TEXT)
    count_axis.xaxis.set_major_formatter(FuncFormatter(lambda value, _: format_count(value)))
    count_axis.tick_params(labelleft=False)

    for axis in (rate_axis, count_axis):
        axis.set_axisbelow(True)
        axis.grid(axis="x", color="#E5EAF0", linewidth=0.8)
        axis.tick_params(axis="x", length=0, labelsize=11)
        axis.tick_params(axis="y", length=0)
        for spine in axis.spines.values():
            spine.set_visible(False)
    for position, row in enumerate(candidates):
        rate_axis.text(rates[position] - 0.2, position,
                       format_percent(row["view_to_cart_conversion"]),
                       ha="right", va="center", fontsize=13, weight="bold",
                       color="white" if position == 0 else TEXT)
        count_axis.text(counts[position] + max(counts) * 0.025, position,
                        format_count(counts[position]),
                        va="center", fontsize=12, weight="bold", color=TEXT)

    fig.text(0.035, 0.135, "Пунктир — общая доля переходов по известным категориям  " + format_percent(baseline),
             fontsize=12, color=TEXT)
    fig.text(0.035, 0.065,
             f"Отбор — от {format_count(MIN_VIEW_SESSIONS)} сессий с просмотром и конверсия ниже общей доли.\n"
             "Порядок — по числу сессий без корзины.", fontsize=11, color=MUTED)
    fig.text(0.035, 0.025,
             "События с неизвестной категорией — " + format_percent(coverage["unnamed_category_share"])
             + " событий core; их доля показана отдельно в README.",
             fontsize=10, color=MUTED)
    fig.savefig(OUTPUT_DIR / "named-category-conversion.png", dpi=160, facecolor="white")
    plt.close(fig)


def create_charts(connection):
    """Читает готовые витрины и сохраняет два графика для README."""
    with connection.cursor(row_factory=dict_row) as cursor:
        cursor.execute("SELECT * FROM mart.funnel_summary")
        summary = cursor.fetchone()
        cursor.execute("SELECT * FROM mart.category_conversion")
        categories = cursor.fetchall()
        cursor.execute("SELECT * FROM mart.category_data_quality")
        coverage = cursor.fetchone()
    if not summary or not summary["view_sessions"] or not categories:
        raise ValueError("Для графиков нужны заполненные витрины магазина и категорий")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    plt.rcParams.update({"font.family": "DejaVu Sans", "text.color": TEXT})
    plot_categories(categories, coverage)
    plot_funnel(summary)


def main():
    settings = read_settings()
    with psycopg.connect(
        host=settings.get("POSTGRES_HOST", "localhost"),
        port=int(settings["POSTGRES_PORT"]),
        dbname=settings["POSTGRES_DB"],
        user=settings["POSTGRES_USER"],
        password=settings["POSTGRES_PASSWORD"],
    ) as connection:
        create_charts(connection)
    print(f"Графики сохранены в {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
