"""Verifica que los stores de Postgres arman el SQL esperado contra un pool
falso que sólo registra qué se le pidió, sin ejecutarlo de verdad — mismo
patrón que test_quota.py:_FakeConn/_FakePool. No hay Postgres real en este
entorno de tests."""
import datetime

from app import accounts, friends, library_store


class _FakeConn:
    def __init__(self, fetchval_return=None, fetchrow_return=None, fetch_return=None):
        self.calls: list[tuple[str, tuple]] = []
        self._fetchval_return = fetchval_return
        self._fetchrow_return = fetchrow_return
        self._fetch_return = fetch_return or []

    async def fetch(self, query, *args):
        self.calls.append((query, args))
        return self._fetch_return

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


async def test_push_history_pasa_datetimes_no_cadenas():
    """**asyncpg no convierte cadenas a `timestamptz`**: pasarle el ISO tal
    cual donde el SQL declara `timestamptz[]` lanza `DataError` en tiempo de
    ejecución (500 para el cliente), y nada en el código lo delata al
    escribirlo. Este test es la única red que atrapa esa regresión sin un
    Postgres real."""

    class _FetchConn(_FakeConn):
        async def fetch(self, query, *args):
            self.calls.append((query, args))
            return [1]

    conn = _FetchConn()
    store = library_store.LibraryStore(_FakePool(conn))
    rows = [
        library_store.HistoryRowIn(
            songId="s1",
            playedAtLocal="2026-08-29T18:00:00",
            playedAtUtc="2026-08-29T23:00:00+00:00",
            playSeconds=120,
        )
    ]
    await store.push_history(1, rows)

    _, args = conn.calls[-1]
    played_at_arg = args[3]
    assert all(isinstance(v, datetime.datetime) for v in played_at_arg), (
        f"played_at debe ser datetime, llegó {[type(v).__name__ for v in played_at_arg]}"
    )
    assert played_at_arg[0].tzinfo is not None


async def test_upsert_no_usa_la_forma_de_fila_completa():
    """`(tabla.*) IS DISTINCT FROM (excluded.*)` es sintaxis arriesgada; se
    comparan columnas explícitas."""
    conn = _FakeConn()

    class _TxConn(_FakeConn):
        def transaction(self):
            return self

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

    conn = _TxConn()
    store = library_store.LibraryStore(_FakePool(conn))
    payload = library_store.LibraryPushPayload(
        baseVersion=0,
        songs=[library_store.LibrarySongIn(songId="a", title="t", artist="ar")],
        playlists=[library_store.LibraryPlaylistIn(playlistId="p", name="n")],
        playlistSongs=[],
    )
    await store.push_library(1, payload)

    queries = " ".join(q for q, _ in conn.calls)
    assert "library_songs.*" not in queries
    assert "library_playlists.*" not in queries
    assert "IS DISTINCT FROM" in queries


async def test_friendship_par_canonico_se_usa_en_status_between():
    conn = _FakeConn(fetchrow_return={"status": "accepted", "requested_by": 5})
    store = friends.FriendsStore(_FakePool(conn))
    result = await store.status_between(9, 5)  # invertido a propósito
    assert result == ("accepted", 5)
    _, args = conn.calls[-1]
    assert args == (5, 9)  # siempre (low, high), sin importar el orden de llamada


async def test_get_history_sin_cursor_no_lleva_clausula_de_arranque():
    conn = _FakeConn(fetch_return=[])
    store = library_store.LibraryStore(_FakePool(conn))
    await store.get_history(1, None, 500)
    query, args = conn.calls[-1]
    assert "played_at, song_id, played_at_local" in query
    assert "OFFSET" not in query  # paginación por clave, nunca por offset
    assert args == (1, 500)


async def test_get_history_con_cursor_pagina_por_clave():
    conn = _FakeConn(fetch_return=[])
    store = library_store.LibraryStore(_FakePool(conn))
    after = (datetime.datetime(2026, 8, 1, tzinfo=datetime.timezone.utc), "s1", "2026-08-01T10:00:00")
    await store.get_history(1, after, 100)
    query, args = conn.calls[-1]
    assert "(played_at, song_id, played_at_local) > ($2, $3, $4)" in query
    # El LIMIT se numera DESPUÉS de los tres del cursor, no fijo en $2.
    assert "LIMIT $5" in query
    assert args == (1, *after, 100)


def test_cursor_de_historial_sobrevive_a_un_id_con_caracteres_raros():
    # song_id y played_at_local son datos del cliente: cualquier separador
    # que se hubiera elegido puede aparecer dentro de ellos.
    row = {
        "playedAtUtc": "2026-08-01T10:00:00+00:00",
        "songId": "id|con:separadores\"y comillas",
        "playedAtLocal": "2026-08-01T10:00:00.000",
    }
    played_at, song_id, local = library_store.decode_history_cursor(
        library_store.encode_history_cursor(row)
    )
    assert song_id == row["songId"]
    assert local == row["playedAtLocal"]
    assert played_at == library_store.parse_played_at(row["playedAtUtc"])


def test_cursor_ilegible_es_invalid_cursor_no_una_excepcion_cualquiera():
    import pytest

    with pytest.raises(library_store.InvalidCursor):
        library_store.decode_history_cursor("esto-no-es-base64-de-json")


async def test_push_library_no_borra_el_source_url_que_subio_otro_dispositivo():
    """Un equipo que reconstruyó su biblioteca escaneando el disco no tiene
    `sourceUrl` (el escáner no puede saber de qué enlace salió un archivo).
    Sin el COALESCE, su push lo pondría a NULL para todos los demás y la
    opción de "actualizar" desaparecería de la cuenta entera."""

    class _TxConn(_FakeConn):
        def transaction(self):
            return self

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

    conn = _TxConn()
    store = library_store.LibraryStore(_FakePool(conn))
    payload = library_store.LibraryPushPayload(
        baseVersion=0,
        songs=[library_store.LibrarySongIn(songId="a", title="t", artist="ar", sourceUrl=None)],
        playlists=[],
        playlistSongs=[],
    )
    await store.push_library(1, payload)

    upsert = next(q for q, _ in conn.calls if "INSERT INTO library_songs" in q)
    assert "source_url = COALESCE(excluded.source_url, library_songs.source_url)" in upsert
