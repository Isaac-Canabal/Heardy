"""Tests de app.library_store — límites de periodo con desfases distintos de
cero. Documenta a propósito que la incoherencia semana/mes es intencional
(réplica exacta de database_helper.dart, ver CLAUDE.md)."""
import datetime

from app import library_store


def _utc(y, m, d, h=0, mi=0) -> datetime.datetime:
    return datetime.datetime(y, m, d, h, mi, tzinfo=datetime.timezone.utc)


def test_week_start_utc_con_desfase_negativo():
    # UTC-5 (Colombia). Martes 2026-08-25 01:00 UTC == lunes 20:00 local
    # del día anterior, así que el lunes local ya empezó: el inicio de
    # semana es el lunes 2026-08-24 00:00 local == 05:00 UTC.
    now = _utc(2026, 8, 25, 1, 0)
    start = library_store.week_start_utc(now, -300)
    assert start == _utc(2026, 8, 24, 5, 0)


def test_week_start_utc_con_desfase_positivo():
    # UTC+13 (Tonga). Lunes 2026-08-24 23:00 UTC == martes 12:00 local: la
    # fecha local ya rodó al día siguiente, así que el "lunes local" es el
    # lunes de la semana que viene desde el punto de vista de UTC.
    now = _utc(2026, 8, 24, 23, 0)
    start = library_store.week_start_utc(now, 780)
    # Lunes local 00:00 == domingo 2026-08-23 11:00 UTC (13h antes).
    assert start == _utc(2026, 8, 23, 11, 0)


def test_month_start_utc_es_el_dia_1_en_el_huso_de_la_cuenta():
    # 24 de agosto a las 12:00 UTC, cuenta en UTC-5: el mes empezó el 1 de
    # agosto a las 00:00 local = 05:00 UTC.
    now = _utc(2026, 8, 24, 12, 0)
    assert library_store.month_start_utc(now, -300) == _utc(2026, 8, 1, 5, 0)


def test_month_start_utc_cambia_de_mes_segun_el_huso():
    # 1 de septiembre a las 02:00 UTC: en UTC-5 todavía es 31 de agosto, así
    # que el mes vigente es agosto.
    now = _utc(2026, 9, 1, 2, 0)
    assert library_store.month_start_utc(now, -300) == _utc(2026, 8, 1, 5, 0)
    # En UTC+2 ya es 1 de septiembre a las 04:00: el mes empezó a las 22:00 UTC del 31.
    assert library_store.month_start_utc(now, 120) == _utc(2026, 8, 31, 22, 0)


def test_period_start_utc_despacha_por_nombre():
    now = _utc(2026, 8, 24, 12, 0)
    assert library_store.period_start_utc("month", now, -300) == library_store.month_start_utc(now, -300)
    assert library_store.period_start_utc("week", now, -300) == library_store.week_start_utc(now, -300)
