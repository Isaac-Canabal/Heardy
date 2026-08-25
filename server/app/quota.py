"""Cupo diario de CANCIONES por identidad (Fase 3 del plan de seguridad).

Deliberadamente distinto de `rate_limit.py`:

- `rate_limit.py` cuenta **peticiones** (`/resolve`, `/playlist`, `/search`,
  `/audio`), vive en memoria y existe como protección anti-abuso —
  desactivado por defecto, un valor holgado alcanza.
- Este módulo cuenta **canciones entregadas de verdad** (sólo `/audio`, y
  sólo cuando responde con éxito) y es persistente en Postgres — un límite de
  producto ("150 al día"), no una defensa. Una canción cuesta 2-3 peticiones
  según de dónde salga (URL pegada, resultado de búsqueda, entrada de
  playlist), así que el limitador de peticiones NUNCA puede sustituir a éste
  sin, en la práctica, dejar un cupo real de 50-75 canciones (trampa 1 del
  plan de seguridad).

Persistente a propósito (hallazgo S3): en memoria, Render duerme el servicio
a los 15 min de inactividad y cualquier despliegue lo reinicia — un cupo
diario que se resetea solo no es un cupo.
"""
from __future__ import annotations

import datetime
from typing import TYPE_CHECKING, Callable, Protocol

if TYPE_CHECKING:
    # Sólo para el type hint de PostgresQuotaStore.__init__ — con `from
    # __future__ import annotations` (arriba) esa anotación nunca se evalúa
    # en tiempo de ejecución, así que este módulo no necesita `asyncpg`
    # instalado para nada más que la conexión real (ver PostgresQuotaStore).
    # Deliberado: los tests de este archivo son de lógica pura y corren con
    # `requirements-dev.txt`, que no incluye asyncpg a propósito — mismo
    # criterio que ya usa este proyecto para no arrastrar yt-dlp a los tests.
    import asyncpg


class QuotaStore(Protocol):
    """La interfaz que `check_quota`/`record_song` necesitan — separada de
    `PostgresQuotaStore` para poder probar la lógica de cupo con un fake en
    memoria, sin una base de datos real corriendo (ver test_quota.py)."""

    async def get_count(self, identity: str, day: datetime.date) -> int: ...

    async def increment(self, identity: str, day: datetime.date) -> int: ...


class PostgresQuotaStore:
    """La única implementación real. `pool` se crea una vez en el lifespan de
    main.py (asyncpg.create_pool es una corrutina, así que no puede vivir a
    nivel de módulo como el semáforo de extracciones) y se comparte entre
    peticiones — un `asyncpg.Pool` ya está pensado para eso."""

    def __init__(self, pool: asyncpg.Pool) -> None:
        self._pool = pool

    async def create_table(self) -> None:
        async with self._pool.acquire() as conn:
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS usage (
                    identity TEXT NOT NULL,
                    day DATE NOT NULL,
                    songs INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (identity, day)
                )
                """
            )

    async def get_count(self, identity: str, day: datetime.date) -> int:
        async with self._pool.acquire() as conn:
            value = await conn.fetchval(
                "SELECT songs FROM usage WHERE identity = $1 AND day = $2", identity, day
            )
            return value or 0

    async def increment(self, identity: str, day: datetime.date) -> int:
        async with self._pool.acquire() as conn:
            return await conn.fetchval(
                """
                INSERT INTO usage (identity, day, songs) VALUES ($1, $2, 1)
                ON CONFLICT (identity, day) DO UPDATE SET songs = usage.songs + 1
                RETURNING songs
                """,
                identity,
                day,
            )


class QuotaExceeded(Exception):
    """Se agotó el cupo del día. `used`/`limit` son lo que `/usage` y el
    cuerpo del 429 le muestran a la app — "llegaste a tus 150 de hoy", no un
    error genérico (D-2 del plan de seguridad)."""

    def __init__(self, used: int, limit: int, retry_after_seconds: int) -> None:
        self.used = used
        self.limit = limit
        self.retry_after_seconds = retry_after_seconds
        super().__init__(f"cupo diario agotado: {used}/{limit}")


Clock = Callable[[], datetime.datetime]


def _utcnow() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def seconds_until_next_day(now: datetime.datetime) -> int:
    """Segundos hasta la medianoche UTC siguiente. El cupo se resetea por
    fecha UTC, no por el huso horario de quien pide — así el mismo cupo no
    "reinicia" en un momento distinto según desde dónde se conecte cada uno.
    Redondea hacia arriba (+1), mismo criterio que `rate_limit.py`: mejor
    pedir un segundo de más que uno de menos."""
    tomorrow = (now + datetime.timedelta(days=1)).date()
    midnight = datetime.datetime.combine(tomorrow, datetime.time.min, tzinfo=datetime.timezone.utc)
    return max(1, int((midnight - now).total_seconds()) + 1)


async def check_quota(
    store: QuotaStore,
    identity: str,
    limit: int,
    *,
    clock: Clock = _utcnow,
) -> tuple[int, int]:
    """Se llama ANTES de gastar presupuesto de extracción en una canción: si
    ya no queda cupo, aborta antes de tocar yt-dlp. `limit <= 0` desactiva el
    cupo (mismo criterio que `rate_limit.py`) y no toca el store para nada.
    Devuelve `(usado, límite)` cuando hay cupo — lo que informa `/usage`."""
    if limit <= 0:
        return (0, 0)
    now = clock()
    today = now.date()
    used = await store.get_count(identity, today)
    if used >= limit:
        raise QuotaExceeded(used, limit, seconds_until_next_day(now))
    return (used, limit)


async def record_song(
    store: QuotaStore,
    identity: str,
    limit: int,
    *,
    clock: Clock = _utcnow,
) -> None:
    """Se llama SÓLO tras entregar los bytes de `/audio` con éxito — nunca en
    un fallo de extracción, un 404 definitivo ni un 415 (sin pista de audio).
    Un fallo no es culpa de quien lo pidió, así que no le gasta cupo."""
    if limit <= 0:
        return
    today = clock().date()
    await store.increment(identity, today)
