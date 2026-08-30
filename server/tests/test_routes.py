"""Tests a nivel de RUTA: peticiones HTTP reales contra la app de FastAPI,
con stores falsos en memoria y la identidad de cuenta sustituida.

**Por qué existe este archivo, dicho sin adornos:** el resto de los tests de
`server/tests/` son de lógica pura (funciones sueltas con fakes), y por eso
dejaron pasar tres bugs seguidos que sólo se ven cuando una petición de
verdad atraviesa la ruta:

1. `POST /history` rechazaba `utcOffsetMinutes` con 422 (`extra_forbidden`)
   porque el modelo del cuerpo no declaraba ese campo, aunque el cliente
   siempre lo manda.
2. `push_history` le pasaba a asyncpg **cadenas** donde el SQL declara
   `timestamptz` — `DataError` en tiempo de ejecución, 500 para el cliente.
3. Los `ON CONFLICT ... WHERE (tabla.*) IS DISTINCT FROM (excluded.*)`
   usaban una forma de fila completa arriesgada en vez de comparar columnas.

Ninguno era un error de lógica: los tres eran errores de CONTRATO, y sólo un
test que mande el cuerpo real por la ruta real los ve.

No se levanta el `lifespan` a propósito (no se usa `with TestClient(...)`):
eso intentaría conectar con Postgres y validar la configuración de
producción, que no es lo que se prueba acá.
"""
from __future__ import annotations

import datetime

import pytest
from fastapi.testclient import TestClient

from app import accounts, config, library_store, main


class FakeUsageStore:
    def __init__(self) -> None:
        self.charges: list[tuple[int, str, int]] = []

    async def get_and_add(self, user_id: int, day: datetime.date, kind: str, amount: int) -> int:
        self.charges.append((user_id, kind, amount))
        return amount


class FakeAccountStore:
    def __init__(self) -> None:
        self.utc_offset: int | None = None
        self.content_hash: str | None = None
        self.version = 0
        self.bumped_with: tuple[int, str | None] | None = None
        self.username: str | None = None

    async def set_utc_offset(self, user_id: int, minutes: int) -> None:
        self.utc_offset = minutes

    async def library_content_hash(self, user_id: int) -> str | None:
        return self.content_hash

    async def bump_library_version(self, user_id, expected_version, content_hash):
        self.bumped_with = (expected_version, content_hash)
        if expected_version != self.version:
            return None  # conflicto de version optimista
        self.version += 1
        return self.version

    async def username_changed_at(self, user_id: int):
        return None

    async def set_username(self, user_id, username, username_key, now) -> None:
        self.username = username


class FakeLibraryStore:
    def __init__(self) -> None:
        self.history_rows: list[library_store.HistoryRowIn] = []
        self.pushed: library_store.LibraryPushPayload | None = None

    async def push_history(self, user_id: int, rows) -> int:
        self.history_rows.extend(rows)
        return len(rows)

    async def prune_old_history(self, user_id: int, retention_days: int) -> None:
        pass

    async def push_library(self, user_id: int, payload) -> None:
        self.pushed = payload


class FakeFriendsStore:
    async def count_accepted(self, user_id: int) -> int:
        return 0


@pytest.fixture
def client(monkeypatch):
    account = accounts.Account(id=1, identity="firebase:test", username="isaac", library_version=0)
    monkeypatch.setattr(main, "_usage_store", FakeUsageStore())
    monkeypatch.setattr(main, "_account_store", FakeAccountStore())
    monkeypatch.setattr(main, "_library_store", FakeLibraryStore())
    monkeypatch.setattr(main, "_friends_store", FakeFriendsStore())
    main.app.dependency_overrides[main.current_account] = lambda: account
    yield TestClient(main.app)
    main.app.dependency_overrides.clear()


def _row(song_id="s1", local="2026-08-29T18:00:00", utc="2026-08-29T23:00:00+00:00", seconds=120):
    return {
        "songId": song_id,
        "playedAtLocal": local,
        "playedAtUtc": utc,
        "playSeconds": seconds,
    }


def test_history_acepta_el_cuerpo_que_el_cliente_manda_de_verdad(client):
    """El cuerpo exacto de `SyncProvider._pushUnsyncedHistory`, incluido
    `utcOffsetMinutes` — el 422 que rompia TODA sincronizacion con sesion."""
    response = client.post("/history", json={"rows": [_row()], "utcOffsetMinutes": -300})
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["received"] == 1
    assert body["stored"] == 1
    assert main._account_store.utc_offset == -300


def test_history_sin_utc_offset_sigue_siendo_valido(client):
    response = client.post("/history", json={"rows": [_row()]})
    assert response.status_code == 200, response.text


def test_history_rechaza_un_campo_de_fila_desconocido(client):
    """`extra="forbid"` sigue protegiendo lo que importa: que no se cuele
    una `uri`/`filePath` del dispositivo (ver CLAUDE.md, "Cloud sync")."""
    bad = _row()
    bad["uri"] = "content://algo/1"
    response = client.post("/history", json={"rows": [bad]})
    assert response.status_code == 422


def test_library_acepta_el_cuerpo_que_el_cliente_manda_de_verdad(client):
    """La proyeccion exacta de `DatabaseHelper.getLibraryIndexRows()`."""
    response = client.put(
        "/library",
        json={
            "baseVersion": 0,
            "contentHash": "hash-1",
            "songs": [
                {
                    "songId": "abc",
                    "title": "Una cancion",
                    "artist": "Alguien",
                    "album": None,
                    "durationSeconds": 210,
                    "fileHash": "abc",
                    "hashKind": "mp4-mdat",
                }
            ],
            "playlists": [{"playlistId": "p1", "name": "Mi playlist", "sortOrder": 0}],
            "playlistSongs": [{"playlistId": "p1", "songId": "abc", "orderIndex": 0}],
        },
    )
    assert response.status_code == 200, response.text
    assert response.json()["version"] == 1
    assert main._library_store.pushed is not None
    assert len(main._library_store.pushed.songs) == 1


def test_library_rechaza_una_uri_del_dispositivo(client):
    """El test de privacidad, ahora tambien a nivel de ruta: una `uri` SAF
    no puede entrar ni por accidente."""
    response = client.put(
        "/library",
        json={
            "baseVersion": 0,
            "songs": [
                {
                    "songId": "abc",
                    "title": "t",
                    "artist": "a",
                    "uri": "content://tree/primary%3AMusic/abc.m4a",
                }
            ],
            "playlists": [],
            "playlistSongs": [],
        },
    )
    assert response.status_code == 422


def test_library_conflicto_de_version_devuelve_409(client):
    main._account_store.version = 5  # el servidor va por 5, el cliente cree que va por 1
    response = client.put(
        "/library",
        json={"baseVersion": 1, "songs": [], "playlists": [], "playlistSongs": []},
    )
    assert response.status_code == 409
    assert response.json()["detail"]["reason"] == "library_version_conflict"


def test_library_atajo_por_content_hash_no_escribe_nada(client):
    main._account_store.content_hash = "sin-cambios"
    response = client.put(
        "/library",
        json={
            "baseVersion": 0,
            "contentHash": "sin-cambios",
            "songs": [],
            "playlists": [],
            "playlistSongs": [],
        },
    )
    assert response.status_code == 200
    assert main._library_store.pushed is None  # ni una escritura
    assert main._account_store.bumped_with is None


def test_account_devuelve_la_forma_que_el_cliente_parsea(client):
    """Los nombres de campo son el contrato de `CloudAccount.fromJson`."""
    response = client.get("/account")
    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"identity", "username", "libraryVersion", "hasLibrary", "friendCount"}


def test_username_invalido_devuelve_400_con_motivo(client):
    response = client.put("/account/username", json={"username": "AB"})
    assert response.status_code == 400
    assert response.json()["detail"]


def test_username_valido_se_guarda(client):
    response = client.put("/account/username", json={"username": "isaac_2026"})
    assert response.status_code == 200, response.text
    assert response.json()["username"] == "isaac_2026"
    assert main._account_store.username == "isaac_2026"


def test_cuerpo_demasiado_grande_se_rechaza_por_content_length(client):
    """`require_upload_size` mira `Content-Length` ANTES de parsear —
    `Field(max_length=...)` validaria despues de leer el cuerpo entero y no
    protegeria de nada."""
    response = client.post(
        "/history",
        content=b'{"rows":[]}',
        headers={
            "Content-Type": "application/json",
            "Content-Length": str(config.MAX_UPLOAD_BYTES + 1),
        },
    )
    assert response.status_code == 413
