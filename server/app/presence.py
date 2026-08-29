"""'Escuchando ahora': presencia en memoria del proceso, nunca en Postgres
(Etapa 16, F8). Ver CLAUDE.md, "Cloud sync", para la contraposición completa
con `quota.py` — aquí memoria es la elección correcta porque una presencia
que se pierde al reiniciar REVOCA algo efímero, al revés que un cupo, que
CONCEDERÍA algo. Un solo worker de uvicorn (misma restricción que
`rate_limit.RateLimiter` y el semáforo de extracciones de main.py) por lo
que ningún método de aquí hace `await` internamente, así que no hace falta
`asyncio.Lock`.

La carga útil es sólo `song_id` — el servidor resuelve el título contra el
índice de QUIEN PUBLICA al leer, así un cliente no puede falsear un título
que no posee.

**`PUT /presence` no escribe ninguna línea de log, ni siquiera la identidad
sola** — se dispara decenas de veces al día por usuario; una línea por
publicación sería una línea temporal de actividad de alta resolución, aunque
la canción nunca aparezca en ella.
"""
from __future__ import annotations

import dataclasses
import time


@dataclasses.dataclass
class _Entry:
    song_id: str
    expires_at: float


class PresenceTracker:
    def __init__(self, *, max_entries: int, max_ttl_seconds: int, clock=time.monotonic) -> None:
        self._entries: dict[int, _Entry] = {}
        self._max_entries = max_entries
        self._max_ttl_seconds = max_ttl_seconds
        self._clock = clock

    def publish(self, user_id: int, song_id: str, ttl_seconds: int) -> None:
        ttl = max(1, min(ttl_seconds, self._max_ttl_seconds))
        self._entries[user_id] = _Entry(song_id, self._clock() + ttl)
        if len(self._entries) > self._max_entries:
            self._sweep()

    def clear(self, user_id: int) -> None:
        self._entries.pop(user_id, None)

    def get(self, user_id: int) -> str | None:
        entry = self._entries.get(user_id)
        if entry is None:
            return None
        if entry.expires_at <= self._clock():
            del self._entries[user_id]
            return None
        return entry.song_id

    def get_many(self, user_ids: list[int]) -> dict[int, str]:
        """Una búsqueda en memoria para pintar la lista de amigos entera —
        nunca N llamadas por amigo."""
        now = self._clock()
        result: dict[int, str] = {}
        for uid in user_ids:
            entry = self._entries.get(uid)
            if entry is not None and entry.expires_at > now:
                result[uid] = entry.song_id
        return result

    def _sweep(self) -> None:
        now = self._clock()
        expired = [uid for uid, entry in self._entries.items() if entry.expires_at <= now]
        for uid in expired:
            del self._entries[uid]

    @property
    def entry_count(self) -> int:
        """Para /health/detail — nunca el contenido, sólo el conteo."""
        return len(self._entries)
