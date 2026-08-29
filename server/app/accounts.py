"""Cuentas: identidad de usuario persistente y nombre de usuario (Etapa 16,
F2). `users` guarda la cadena `identity` (`firebase:<uid>`) UNA sola vez;
todo lo demás (biblioteca, historial, amistades) referencia `users.id
BIGINT` — en el historial de reproducción es la diferencia entre ~140 y ~100
bytes por fila, la decisión de esquema más importante de todo este trabajo
sobre 0.5 GB de Neon (ver CLAUDE.md).

`GET /account` (en main.py) es lo que hace que una cuenta "adopte" la
biblioteca que ya vive en el dispositivo: `get_or_create` crea la fila de
`users` en el primer login, sin ningún paso de migración — la biblioteca
sigue en SQLite local y sólo gana un dueño cuando el cliente hace el primer
`PUT /library` (ver library_store.py).
"""
from __future__ import annotations

import dataclasses
import datetime
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    import asyncpg


@dataclasses.dataclass
class Account:
    id: int
    identity: str
    username: str | None
    library_version: int


class UsernameTaken(Exception):
    """`INSERT ... ON CONFLICT` capturó una UniqueViolationError — nunca se
    comprueba disponibilidad y luego se inserta: eso es una carrera entre dos
    personas eligiendo el mismo nombre al mismo tiempo."""


class UsernameCooldown(Exception):
    def __init__(self, retry_after_seconds: int) -> None:
        self.retry_after_seconds = retry_after_seconds
        super().__init__("cambiaste de nombre de usuario hace poco")


class AccountStore(Protocol):
    async def get_or_create(self, identity: str) -> Account: ...

    async def find_by_username(self, username_key: str) -> Account | None: ...

    async def username_changed_at(self, user_id: int) -> datetime.datetime | None: ...

    async def set_username(
        self, user_id: int, username: str, username_key: str, now: datetime.datetime
    ) -> None: ...

    async def bump_library_version(
        self, user_id: int, expected_version: int, content_hash: str | None
    ) -> int | None:
        """Sube `library_version` en uno si `expected_version` coincide.
        Devuelve la versión nueva, o None si no coincidió (409 en main.py)."""
        ...

    async def library_content_hash(self, user_id: int) -> str | None: ...

    async def get_by_id(self, user_id: int) -> Account | None: ...

    async def set_utc_offset(self, user_id: int, minutes: int) -> None: ...

    async def set_share_now_playing(self, user_id: int, enabled: bool) -> None: ...

    async def share_now_playing(self, user_id: int) -> bool: ...

    async def delete_account_data(self, user_id: int) -> None:
        """Borra biblioteca/historial/amistades de la cuenta — la válvula de
        escape de privacidad (`DELETE /account/data`). No borra la fila de
        `users` en sí: el identity/username quedan, para que un revínculo
        posterior no tenga que reclamar el nombre otra vez."""
        ...


class UsageStore(Protocol):
    """Presupuestos diarios POR CUENTA: búsquedas de usuario, solicitudes de
    amistad, subidas de biblioteca/historial. Deliberadamente distinto de
    `quota.py` (que cuenta canciones entregadas) y de `rate_limit.py` (que
    cuenta peticiones en memoria, por clave de API) — éste cuenta por
    `(user_id, day, kind)` en Postgres, porque una cuenta social exige correo
    verificado y tiene un coste real de creación, así que rotar de cuenta no
    es gratis como rotar de IP."""

    async def get_and_add(self, user_id: int, day: datetime.date, kind: str, amount: int) -> int:
        """Suma `amount` al contador de hoy para `(user_id, kind)` y devuelve
        el total resultante, en una sola operación atómica (evita la carrera
        de leer-luego-escribir entre dos peticiones concurrentes)."""
        ...


class UsageExceeded(Exception):
    def __init__(self, kind: str, used: int, limit: int) -> None:
        self.kind = kind
        self.used = used
        self.limit = limit
        super().__init__(f"cupo diario de {kind} agotado: {used}/{limit}")


def _utcnow() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


async def check_and_add(
    store: UsageStore,
    user_id: int,
    kind: str,
    amount: int,
    limit: int,
    *,
    clock=_utcnow,
) -> int:
    """Cobra `amount` contra el presupuesto diario de `kind` para esta
    cuenta. `limit <= 0` desactiva el límite y no toca el store — mismo
    criterio que `quota.py`/`rate_limit.py`. Cobra una CANTIDAD, no un golpe
    por petición: una subida de historial de 500 filas cuesta 500, no 1 — el
    mecanismo que hace viable la migración masiva de un usuario existente
    (ver server/README.md, "Migración")."""
    if limit <= 0:
        return 0
    today = clock().date()
    total = await store.get_and_add(user_id, today, kind, amount)
    if total > limit:
        raise UsageExceeded(kind, total, limit)
    return total


class PostgresAccountStore:
    """La única implementación real de AccountStore. `pool` se comparte con
    el resto de stores de la Parte A — un único `asyncpg.Pool` por proceso
    (ver main.py:lifespan)."""

    def __init__(self, pool: asyncpg.Pool) -> None:
        self._pool = pool

    async def create_table(self) -> None:
        async with self._pool.acquire() as conn:
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id BIGSERIAL PRIMARY KEY,
                    identity TEXT NOT NULL UNIQUE,
                    username TEXT,
                    username_key TEXT UNIQUE,
                    username_changed_at TIMESTAMPTZ,
                    utc_offset_minutes INT NOT NULL DEFAULT 0,
                    library_version BIGINT NOT NULL DEFAULT 0,
                    library_content_hash TEXT,
                    share_now_playing BOOLEAN NOT NULL DEFAULT FALSE,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
                """
            )
            # A8 del plan: CREATE TABLE IF NOT EXISTS no añade columnas a una
            # tabla ya existente. Cada create_table termina con esta lista,
            # vacía al principio — el mismo patrón que _onUpgrade en el
            # cliente Dart.
            await conn.execute(
                "ALTER TABLE users ADD COLUMN IF NOT EXISTS share_now_playing BOOLEAN NOT NULL DEFAULT FALSE"
            )
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS account_usage (
                    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    day DATE NOT NULL,
                    kind TEXT NOT NULL,
                    amount INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (user_id, day, kind)
                )
                """
            )

    async def get_or_create(self, identity: str) -> Account:
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                """
                INSERT INTO users (identity) VALUES ($1)
                ON CONFLICT (identity) DO UPDATE SET identity = users.identity
                RETURNING id, identity, username, library_version
                """,
                identity,
            )
            return Account(row["id"], row["identity"], row["username"], row["library_version"])

    async def find_by_username(self, username_key: str) -> Account | None:
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT id, identity, username, library_version FROM users WHERE username_key = $1",
                username_key,
            )
            if row is None:
                return None
            return Account(row["id"], row["identity"], row["username"], row["library_version"])

    async def username_changed_at(self, user_id: int) -> datetime.datetime | None:
        async with self._pool.acquire() as conn:
            return await conn.fetchval(
                "SELECT username_changed_at FROM users WHERE id = $1", user_id
            )

    async def set_username(
        self, user_id: int, username: str, username_key: str, now: datetime.datetime
    ) -> None:
        import asyncpg as _asyncpg  # import local: sólo hace falta aquí para capturar la excepción

        async with self._pool.acquire() as conn:
            try:
                await conn.execute(
                    """
                    UPDATE users SET username = $2, username_key = $3, username_changed_at = $4
                    WHERE id = $1
                    """,
                    user_id,
                    username,
                    username_key,
                    now,
                )
            except _asyncpg.UniqueViolationError as e:
                raise UsernameTaken() from e

    async def bump_library_version(
        self, user_id: int, expected_version: int, content_hash: str | None
    ) -> int | None:
        async with self._pool.acquire() as conn:
            new_version = await conn.fetchval(
                """
                UPDATE users SET library_version = library_version + 1, library_content_hash = $3
                WHERE id = $1 AND library_version = $2
                RETURNING library_version
                """,
                user_id,
                expected_version,
                content_hash,
            )
            return new_version

    async def library_content_hash(self, user_id: int) -> str | None:
        async with self._pool.acquire() as conn:
            return await conn.fetchval(
                "SELECT library_content_hash FROM users WHERE id = $1", user_id
            )

    async def get_by_id(self, user_id: int) -> Account | None:
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT id, identity, username, library_version FROM users WHERE id = $1", user_id
            )
            if row is None:
                return None
            return Account(row["id"], row["identity"], row["username"], row["library_version"])

    async def set_utc_offset(self, user_id: int, minutes: int) -> None:
        async with self._pool.acquire() as conn:
            await conn.execute("UPDATE users SET utc_offset_minutes = $2 WHERE id = $1", user_id, minutes)

    async def set_share_now_playing(self, user_id: int, enabled: bool) -> None:
        async with self._pool.acquire() as conn:
            await conn.execute(
                "UPDATE users SET share_now_playing = $2 WHERE id = $1", user_id, enabled
            )

    async def share_now_playing(self, user_id: int) -> bool:
        async with self._pool.acquire() as conn:
            return bool(
                await conn.fetchval("SELECT share_now_playing FROM users WHERE id = $1", user_id)
            )

    async def delete_account_data(self, user_id: int) -> None:
        # library_* y play_history no tienen FK contra users a propósito
        # (ver library_store.py) así que se borran a mano, en una
        # transacción; friendships sí referencia users, pero se borra igual
        # de forma explícita para no depender del orden de los ON DELETE.
        async with self._pool.acquire() as conn:
            async with conn.transaction():
                await conn.execute("DELETE FROM library_songs WHERE user_id = $1", user_id)
                await conn.execute("DELETE FROM library_playlists WHERE user_id = $1", user_id)
                await conn.execute("DELETE FROM library_playlist_songs WHERE user_id = $1", user_id)
                await conn.execute("DELETE FROM play_history WHERE user_id = $1", user_id)
                await conn.execute(
                    "DELETE FROM friendships WHERE user_low_id = $1 OR user_high_id = $1", user_id
                )
                await conn.execute(
                    """
                    UPDATE users SET library_version = 0, library_content_hash = NULL
                    WHERE id = $1
                    """,
                    user_id,
                )


class PostgresUsageStore:
    def __init__(self, pool: asyncpg.Pool) -> None:
        self._pool = pool

    async def get_and_add(self, user_id: int, day: datetime.date, kind: str, amount: int) -> int:
        async with self._pool.acquire() as conn:
            return await conn.fetchval(
                """
                INSERT INTO account_usage (user_id, day, kind, amount) VALUES ($1, $2, $3, $4)
                ON CONFLICT (user_id, day, kind) DO UPDATE SET amount = account_usage.amount + $4
                RETURNING amount
                """,
                user_id,
                day,
                kind,
                amount,
            )
