"""Verifica que los stores de Postgres arman el SQL esperado contra un pool
falso que sólo registra qué se le pidió, sin ejecutarlo de verdad — mismo
patrón que test_quota.py:_FakeConn/_FakePool. No hay Postgres real en este
entorno de tests."""
import datetime

from app import accounts, friends


class _FakeConn:
    def __init__(self, fetchval_return=None, fetchrow_return=None):
        self.calls: list[tuple[str, tuple]] = []
        self._fetchval_return = fetchval_return
        self._fetchrow_return = fetchrow_return

    async def execute(self, query, *args):
        self.calls.append((query, args))

    async def fetchval(self, query, *args):
        self.calls.append((query, args))
        return self._fetchval_return

    async def fetchrow(self, query, *args):
        self.calls.append((query, args))
        return self._fetchrow_return

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False


class _FakePool:
    def __init__(self, conn):
        self._conn = conn

    def acquire(self):
        return self._conn


async def test_bump_library_version_genera_el_update_optimista():
    conn = _FakeConn(fetchval_return=5)
    store = accounts.PostgresAccountStore(_FakePool(conn))
    result = await store.bump_library_version(1, 4, "hash123")
    assert result == 5
    query, args = conn.calls[-1]
    assert "library_version = library_version + 1" in query
    assert args == (1, 4, "hash123")


async def test_get_or_create_usa_on_conflict_do_update():
    conn = _FakeConn(
        fetchrow_return={"id": 1, "identity": "firebase:abc", "username": None, "library_version": 0}
    )
    store = accounts.PostgresAccountStore(_FakePool(conn))
    account = await store.get_or_create("firebase:abc")
    assert account.id == 1
    query, _ = conn.calls[-1]
    assert "ON CONFLICT (identity) DO UPDATE" in query


async def test_usage_store_upsert_suma_amount():
    conn = _FakeConn(fetchval_return=42)
    store = accounts.PostgresUsageStore(_FakePool(conn))
    result = await store.get_and_add(1, datetime.date(2026, 8, 24), "lookup", 5)
    assert result == 42
    query, args = conn.calls[-1]
    assert "ON CONFLICT (user_id, day, kind) DO UPDATE" in query
    assert args == (1, datetime.date(2026, 8, 24), "lookup", 5)


async def test_friendship_par_canonico_se_usa_en_status_between():
    conn = _FakeConn(fetchrow_return={"status": "accepted", "requested_by": 5})
    store = friends.FriendsStore(_FakePool(conn))
    result = await store.status_between(9, 5)  # invertido a propósito
    assert result == ("accepted", 5)
    _, args = conn.calls[-1]
    assert args == (5, 9)  # siempre (low, high), sin importar el orden de llamada
