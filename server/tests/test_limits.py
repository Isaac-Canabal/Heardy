"""Tests de app.accounts.check_and_add — presupuestos diarios POR CUENTA
(búsquedas, solicitudes de amistad, subidas de biblioteca/historial).
Calcado de test_quota.py: límite 0 no toca el store, aislamiento por kind y
por usuario, cruce de medianoche. Distinto de quota.py en que cobra una
CANTIDAD, no un golpe por petición — ver docstring de check_and_add."""
import datetime

import pytest

from app import accounts


class FakeUsageStore:
    def __init__(self) -> None:
        self.counts: dict[tuple[int, datetime.date, str], int] = {}

    async def get_and_add(self, user_id: int, day: datetime.date, kind: str, amount: int) -> int:
        key = (user_id, day, kind)
        self.counts[key] = self.counts.get(key, 0) + amount
        return self.counts[key]


class FakeClock:
    def __init__(self, start: datetime.datetime) -> None:
        self._now = start

    def __call__(self) -> datetime.datetime:
        return self._now

    def advance(self, **kwargs) -> None:
        self._now += datetime.timedelta(**kwargs)


def _utc(y, m, d, h=0) -> datetime.datetime:
    return datetime.datetime(y, m, d, h, tzinfo=datetime.timezone.utc)


async def test_limite_cero_desactiva_y_no_toca_el_store():
    store = FakeUsageStore()
    total = await accounts.check_and_add(store, 1, "lookup", 1, 0, clock=FakeClock(_utc(2026, 8, 24)))
    assert total == 0
    assert store.counts == {}


async def test_cobra_por_cantidad_no_por_golpe():
    store = FakeUsageStore()
    clock = FakeClock(_utc(2026, 8, 24))
    total = await accounts.check_and_add(store, 1, "history_upload", 500, 200000, clock=clock)
    assert total == 500
    total = await accounts.check_and_add(store, 1, "history_upload", 500, 200000, clock=clock)
    assert total == 1000


async def test_aisla_por_kind():
    store = FakeUsageStore()
    clock = FakeClock(_utc(2026, 8, 24))
    await accounts.check_and_add(store, 1, "lookup", 10, 60, clock=clock)
    total_friend_requests = await accounts.check_and_add(store, 1, "friend_request", 1, 20, clock=clock)
    assert total_friend_requests == 1


async def test_aisla_por_usuario():
    store = FakeUsageStore()
    clock = FakeClock(_utc(2026, 8, 24))
    await accounts.check_and_add(store, 1, "lookup", 60, 60, clock=clock)
    total_other_user = await accounts.check_and_add(store, 2, "lookup", 1, 60, clock=clock)
    assert total_other_user == 1


async def test_al_superar_el_limite_lanza_usage_exceeded():
    store = FakeUsageStore()
    clock = FakeClock(_utc(2026, 8, 24))
    with pytest.raises(accounts.UsageExceeded) as exc:
        await accounts.check_and_add(store, 1, "lookup", 61, 60, clock=clock)
    assert exc.value.used == 61
    assert exc.value.limit == 60
    assert exc.value.kind == "lookup"


async def test_cruce_de_medianoche_resetea():
    store = FakeUsageStore()
    clock = FakeClock(_utc(2026, 8, 24, 23))
    await accounts.check_and_add(store, 1, "lookup", 60, 60, clock=clock)
    clock.advance(hours=2)
    total = await accounts.check_and_add(store, 1, "lookup", 1, 60, clock=clock)
    assert total == 1
