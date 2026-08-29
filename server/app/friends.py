"""Amistades: par canónico ordenado, no una fila por dirección (Etapa 16,
F7). El error clásico de guardar (requester, addressee) es que A→B y B→A
crean dos filas y ninguna queda aceptada; con el par ordenado en la PK, la
base garantiza una fila por par sin importar quién pidió primero. La
dirección de la solicitud vive aparte, en `requested_by`.
"""
from __future__ import annotations

import dataclasses
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    import asyncpg


def canonical_pair(a: int, b: int) -> tuple[int, int]:
    """(low, high). Nunca a == b — llamar con el mismo id dos veces es un
    error de quien llama, no un caso a manejar en silencio."""
    if a == b:
        raise ValueError("un usuario no puede ser amigo de sí mismo")
    return (a, b) if a < b else (b, a)


@dataclasses.dataclass
class FriendshipResult:
    status: str  # "pending" | "accepted"


class AlreadyFriends(Exception):
    pass


class SelfRequest(Exception):
    pass


class RequestNotFound(Exception):
    pass


class TooManyPending(Exception):
    pass


class TooManyFriends(Exception):
    pass


class FriendsStore:
    def __init__(self, pool: asyncpg.Pool) -> None:
        self._pool = pool

    async def create_table(self) -> None:
        async with self._pool.acquire() as conn:
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS friendships (
                    user_low_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    user_high_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    status TEXT NOT NULL CHECK (status IN ('pending', 'accepted', 'blocked')),
                    requested_by BIGINT NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    PRIMARY KEY (user_low_id, user_high_id),
                    CONSTRAINT friendships_orden CHECK (user_low_id < user_high_id)
                )
                """
            )

    async def status_between(self, a: int, b: int) -> tuple[str, int] | None:
        low, high = canonical_pair(a, b)
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT status, requested_by FROM friendships WHERE user_low_id = $1 AND user_high_id = $2",
                low,
                high,
            )
            if row is None:
                return None
            return row["status"], row["requested_by"]

    async def count_accepted(self, user_id: int) -> int:
        async with self._pool.acquire() as conn:
            return await conn.fetchval(
                """
                SELECT COUNT(*) FROM friendships
                WHERE (user_low_id = $1 OR user_high_id = $1) AND status = 'accepted'
                """,
                user_id,
            )

    async def count_pending_outgoing(self, user_id: int) -> int:
        async with self._pool.acquire() as conn:
            return await conn.fetchval(
                """
                SELECT COUNT(*) FROM friendships
                WHERE (user_low_id = $1 OR user_high_id = $1)
                  AND status = 'pending' AND requested_by = $1
                """,
                user_id,
            )

    async def request(self, from_id: int, to_id: int) -> FriendshipResult:
        """Solicitudes: a sí mismo → SelfRequest (400 en main.py); ya amigos
        → AlreadyFriends (409); repetir la propia solicitud → idempotente
        (200, sigue "pending"); si existe la inversa pendiente, se acepta —
        interés mutuo es amistad, y es la única forma de que dos solicitudes
        cruzadas no se traben esperándose la una a la otra."""
        if from_id == to_id:
            raise SelfRequest()
        low, high = canonical_pair(from_id, to_id)
        async with self._pool.acquire() as conn:
            async with conn.transaction():
                row = await conn.fetchrow(
                    "SELECT status, requested_by FROM friendships WHERE user_low_id = $1 AND user_high_id = $2 FOR UPDATE",
                    low,
                    high,
                )
                if row is None:
                    await conn.execute(
                        """
                        INSERT INTO friendships (user_low_id, user_high_id, status, requested_by)
                        VALUES ($1, $2, 'pending', $3)
                        """,
                        low,
                        high,
                        from_id,
                    )
                    return FriendshipResult("pending")
                if row["status"] == "accepted":
                    raise AlreadyFriends()
                if row["requested_by"] == from_id:
                    return FriendshipResult("pending")  # repetir la propia: idempotente
                # La otra persona ya lo había pedido: interés mutuo, se acepta.
                await conn.execute(
                    "UPDATE friendships SET status = 'accepted' WHERE user_low_id = $1 AND user_high_id = $2",
                    low,
                    high,
                )
                return FriendshipResult("accepted")

    async def accept(self, user_id: int, other_id: int) -> None:
        low, high = canonical_pair(user_id, other_id)
        async with self._pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT status, requested_by FROM friendships WHERE user_low_id = $1 AND user_high_id = $2",
                low,
                high,
            )
            # Sólo quien RECIBIÓ la solicitud puede aceptarla.
            if row is None or row["status"] != "pending" or row["requested_by"] == user_id:
                raise RequestNotFound()
            await conn.execute(
                "UPDATE friendships SET status = 'accepted' WHERE user_low_id = $1 AND user_high_id = $2",
                low,
                high,
            )

    async def remove(self, a: int, b: int) -> None:
        """Cubre las tres acciones del cliente (rechazar entrante, cancelar
        saliente, eliminar amigo ya aceptado): todas son, en la base, borrar
        la fila del par — la diferencia es sólo qué botón la disparó."""
        low, high = canonical_pair(a, b)
        async with self._pool.acquire() as conn:
            await conn.execute(
                "DELETE FROM friendships WHERE user_low_id = $1 AND user_high_id = $2", low, high
            )

    async def list_for(self, user_id: int) -> dict:
        async with self._pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT user_low_id, user_high_id, status, requested_by
                FROM friendships WHERE user_low_id = $1 OR user_high_id = $1
                """,
                user_id,
            )
        friends, incoming, outgoing = [], [], []
        for row in rows:
            other = row["user_high_id"] if row["user_low_id"] == user_id else row["user_low_id"]
            if row["status"] == "accepted":
                friends.append(other)
            elif row["requested_by"] == user_id:
                outgoing.append(other)
            else:
                incoming.append(other)
        return {"friends": friends, "incoming": incoming, "outgoing": outgoing}
