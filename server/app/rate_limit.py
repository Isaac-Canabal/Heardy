"""Límite de peticiones: ventana deslizante por clave + tope diario global.

Pensado para el servidor oficial compartido (varias personas detrás del
mismo presupuesto de IP frente a YouTube). Un servidor personal de un solo
usuario lo deja desactivado por defecto (`HEARDY_RATE_LIMIT_PER_KEY=0` y
`HEARDY_DAILY_QUOTA=0`), que es exactamente el comportamiento de antes de
que este módulo existiera — nada cambia para quien no toque esas variables.

El `Retry-After` que se devuelve siempre se calcula a partir de la propia
ventana, nunca es un número inventado (ver docs/arquitectura_servidor_hibrido.md,
sección 5.1). Para el caso en el que YouTube mismo bloquea la IP (sección
5.2 del mismo documento), este módulo no interviene a propósito: ese fallo
sigue saliendo como 502/404 desde `_extraction_error` en main.py, sin
`Retry-After`, porque el servidor no puede conocer ese tiempo con certeza —
inventarlo sería peor que no darlo.
"""
import time
from collections import defaultdict, deque
from typing import Callable

from fastapi import Depends, HTTPException, status

from . import config
from .auth import resolve_identity


class RateLimitExceeded(Exception):
    """Se agotó la cuota. `scope` distingue si fue la ventana de esta clave
    ("per-key") o el tope diario compartido por todas ("global") — importa
    para decidir qué mensaje mostrar y a quién."""

    def __init__(self, retry_after_seconds: int, scope: str) -> None:
        self.retry_after_seconds = retry_after_seconds
        self.scope = scope
        super().__init__(
            f"límite de peticiones alcanzado ({scope}), reintentar en {retry_after_seconds}s"
        )


class RateLimiter:
    """Cuenta peticiones por identidad y globalmente, en memoria.

    En un solo proceso de asyncio (el caso de este servicio: un worker de
    uvicorn, igual que el semáforo de `MAX_CONCURRENT_EXTRACTIONS` en
    main.py) no hace falta un `asyncio.Lock`: `check()` no tiene ningún
    `await` interno, así que el bucle de eventos nunca puede intercalar dos
    llamadas a mitad de la función.
    """

    def __init__(
        self,
        per_key_limit: int,
        per_key_window_seconds: int,
        daily_quota: int,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._per_key_limit = per_key_limit
        self._per_key_window = per_key_window_seconds
        self._daily_quota = daily_quota
        self._clock = clock
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._daily_hits: deque[float] = deque()

    async def check(self, identity: str) -> None:
        """Registra una petición de `identity`, o lanza RateLimitExceeded
        sin registrarla si ya no queda cuota."""
        if self._per_key_limit <= 0 and self._daily_quota <= 0:
            return

        now = self._clock()

        if self._per_key_limit > 0:
            window = self._hits[identity]
            self._evict(window, now, self._per_key_window)
            if len(window) >= self._per_key_limit:
                raise RateLimitExceeded(self._retry_after(window, self._per_key_window, now), "per-key")

        if self._daily_quota > 0:
            self._evict(self._daily_hits, now, 86400)
            if len(self._daily_hits) >= self._daily_quota:
                raise RateLimitExceeded(self._retry_after(self._daily_hits, 86400, now), "global")

        if self._per_key_limit > 0:
            self._hits[identity].append(now)
        if self._daily_quota > 0:
            self._daily_hits.append(now)

    @staticmethod
    def _evict(window: deque, now: float, seconds: int) -> None:
        cutoff = now - seconds
        while window and window[0] < cutoff:
            window.popleft()

    @staticmethod
    def _retry_after(window: deque, seconds: int, now: float) -> int:
        # Redondea hacia arriba (+1) para no decirle nunca al cliente que
        # reintente un instante antes de que la ventana se haya liberado de
        # verdad — mejor pedirle un segundo de más que uno de menos.
        remaining = (window[0] + seconds) - now
        return max(1, int(remaining) + 1)


_limiter = RateLimiter(
    per_key_limit=config.RATE_LIMIT_PER_KEY,
    per_key_window_seconds=config.RATE_LIMIT_WINDOW_SECONDS,
    daily_quota=config.DAILY_QUOTA,
)


async def enforce_rate_limit(identity: str = Depends(resolve_identity)) -> str:
    """Dependencia de FastAPI: autentica (delegado a `resolve_identity` —
    X-Api-Key o Bearer de Firebase, cualquiera de los dos) y además exige
    cuota. Se usa solo en los endpoints que gastan presupuesto de IP frente a
    YouTube (/resolve, /playlist, /search, /audio) — no en /cache/
    /health/detail, que son administrativos y van por `require_admin`
    (API-key-only, ver auth.py) en vez de por acá."""
    try:
        await _limiter.check(identity)
    except RateLimitExceeded as e:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=str(e),
            headers={"Retry-After": str(e.retry_after_seconds)},
        ) from e
    return identity
