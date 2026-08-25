"""Tests de app.quota — con un store en memoria (implementa el Protocol
QuotaStore, nunca toca Postgres de verdad) y un reloj falso inyectado, igual
que test_rate_limit.py hace con RateLimiter. La conexión real a Neon/Postgres
(PostgresQuotaStore) sólo se ejercita en vivo, no acá — mismo criterio que el
resto de este proyecto para todo lo que depende de infraestructura externa."""
import datetime

import pytest

from app import quota


class FakeQuotaStore:
    """Un dict en memoria (identity, día) -> canciones. Suficiente para
    probar check_quota/record_song sin una base de datos real."""

    def __init__(self) -> None:
        self.counts: dict[tuple[str, datetime.date], int] = {}

    async def get_count(self, identity: str, day: datetime.date) -> int:
        return self.counts.get((identity, day), 0)

    async def increment(self, identity: str, day: datetime.date) -> int:
        key = (identity, day)
        self.counts[key] = self.counts.get(key, 0) + 1
        return self.counts[key]


class FakeClock:
    def __init__(self, start: datetime.datetime) -> None:
        self._now = start

    def __call__(self) -> datetime.datetime:
        return self._now

    def advance(self, **kwargs) -> None:
        self._now += datetime.timedelta(**kwargs)


def _utc(y, m, d, h=0, mi=0, s=0) -> datetime.datetime:
    return datetime.datetime(y, m, d, h, mi, s, tzinfo=datetime.timezone.utc)


def test_seconds_until_next_day_redondea_hacia_arriba():
    # A un segundo exacto de medianoche: 1s reales, pero +1 de margen — mismo
    # criterio que rate_limit.py, mejor pedir de más que de menos.
    now = _utc(2026, 8, 24, 23, 59, 59)
    assert quota.seconds_until_next_day(now) == 2


def test_seconds_until_next_day_justo_despues_de_medianoche():
    now = _utc(2026, 8, 25, 0, 0, 1)
    # Casi el día entero por delante.
    assert 86390 <= quota.seconds_until_next_day(now) <= 86400


async def test_limite_cero_desactiva_y_no_toca_el_store():
    store = FakeQuotaStore()
    used, limit = await quota.check_quota(store, "isaac", 0, clock=FakeClock(_utc(2026, 8, 24)))
    assert (used, limit) == (0, 0)
    assert store.counts == {}  # ni siquiera se leyó/escribió nada


async def test_limite_cero_record_song_no_incrementa():
    store = FakeQuotaStore()
    await quota.record_song(store, "isaac", 0, clock=FakeClock(_utc(2026, 8, 24)))
    assert store.counts == {}


async def test_bajo_el_limite_no_lanza_y_devuelve_uso_actual():
    store = FakeQuotaStore()
    clock = FakeClock(_utc(2026, 8, 24, 10))
    await quota.record_song(store, "isaac", 150, clock=clock)
    await quota.record_song(store, "isaac", 150, clock=clock)

    used, limit = await quota.check_quota(store, "isaac", 150, clock=clock)
    assert (used, limit) == (2, 150)


async def test_al_llegar_al_limite_lanza_quota_exceeded():
    store = FakeQuotaStore()
    clock = FakeClock(_utc(2026, 8, 24, 12))
    for _ in range(3):
        await quota.record_song(store, "isaac", 3, clock=clock)

    with pytest.raises(quota.QuotaExceeded) as exc:
        await quota.check_quota(store, "isaac", 3, clock=clock)
    assert exc.value.used == 3
    assert exc.value.limit == 3
    assert exc.value.retry_after_seconds > 0


async def test_el_cupo_no_se_comparte_entre_identidades():
    store = FakeQuotaStore()
    clock = FakeClock(_utc(2026, 8, 24, 12))
    for _ in range(3):
        await quota.record_song(store, "isaac", 3, clock=clock)

    # "ana" tiene su propio cupo, sin tocar por el de isaac.
    used, limit = await quota.check_quota(store, "ana", 3, clock=clock)
    assert (used, limit) == (0, 3)


async def test_un_fallo_no_gasta_cupo():
    """Simula el flujo real de main.py: check_quota (antes de extraer) no
    incrementa por sí solo — sólo record_song lo hace, y eso sólo se llama
    tras una entrega exitosa. Un vídeo borrado/bloqueado nunca llama a
    record_song, así que el cupo de quien lo pidió queda intacto."""
    store = FakeQuotaStore()
    clock = FakeClock(_utc(2026, 8, 24, 12))

    await quota.check_quota(store, "isaac", 150, clock=clock)  # sólo mirar
    await quota.check_quota(store, "isaac", 150, clock=clock)
    await quota.check_quota(store, "isaac", 150, clock=clock)

    used, _ = await quota.check_quota(store, "isaac", 150, clock=clock)
    assert used == 0


async def test_un_acierto_de_cache_sigue_contando():
    """/audio sirve desde caché en disco sin volver a pedirle nada a
    YouTube (ver app/cache.py) — pero desde el punto de vista del cupo
    diario sigue siendo "una canción entregada", así que record_song se
    llama igual. Acá se comprueba sólo la mitad de quota.py que le toca:
    llamarlo dos veces (como haría main.py en dos pedidos del mismo vídeo,
    el segundo servido desde caché) incrementa las dos veces."""
    store = FakeQuotaStore()
    clock = FakeClock(_utc(2026, 8, 24, 12))

    await quota.record_song(store, "isaac", 150, clock=clock)  # primera vez
    await quota.record_song(store, "isaac", 150, clock=clock)  # "cache hit"

    used, _ = await quota.check_quota(store, "isaac", 150, clock=clock)
    assert used == 2


async def test_cruce_de_medianoche_resetea_el_cupo():
    store = FakeQuotaStore()
    clock = FakeClock(_utc(2026, 8, 24, 23, 0))
    for _ in range(3):
        await quota.record_song(store, "isaac", 3, clock=clock)
    with pytest.raises(quota.QuotaExceeded):
        await quota.check_quota(store, "isaac", 3, clock=clock)

    clock.advance(hours=2)  # cruza a las 01:00 UTC del día siguiente
    used, limit = await quota.check_quota(store, "isaac", 3, clock=clock)
    assert (used, limit) == (0, 3)


async def test_postgres_quota_store_genera_el_sql_esperado():
    """No hay Postgres real en este entorno de tests — se verifica que
    PostgresQuotaStore.increment/get_count arman el SQL correcto contra un
    pool falso que sólo registra qué se le pidió, sin ejecutarlo de verdad."""

    class _FakeConn:
        def __init__(self):
            self.calls: list[tuple[str, tuple]] = []

        async def execute(self, query, *args):
            self.calls.append((query, args))

        async def fetchval(self, query, *args):
            self.calls.append((query, args))
            return 7

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

    class _FakePool:
        def __init__(self, conn):
            self._conn = conn

        def acquire(self):
            return self._conn

    conn = _FakeConn()
    store = quota.PostgresQuotaStore(_FakePool(conn))

    result = await store.get_count("isaac", datetime.date(2026, 8, 24))
    assert result == 7
    assert "SELECT songs FROM usage" in conn.calls[-1][0]

    result = await store.increment("isaac", datetime.date(2026, 8, 24))
    assert result == 7
    assert "ON CONFLICT (identity, day)" in conn.calls[-1][0]
