"""Índice de biblioteca e historial de reproducción, sincronizados por
cuenta (Etapa 16, F3). Ver CLAUDE.md, "Cloud sync": el servidor guarda un
ÍNDICE — títulos, artistas, playlists, pertenencia, historial — nunca audio
ni nada que sólo signifique algo en el dispositivo que lo produjo (`uri`,
`filePath`, `artPath`, `modifiedAt`, `missing`, `ignoredFromInbox`).
"""
from __future__ import annotations

import dataclasses
import datetime
import re
from typing import TYPE_CHECKING

from pydantic import BaseModel, ConfigDict, Field

if TYPE_CHECKING:
    import asyncpg


# --- Payloads --------------------------------------------------------------
#
# `extra="forbid"` es la lista explícita de A2 hecha cumplir por el propio
# framework: un campo no declarado (uri, filePath, artPath, modifiedAt,
# missing, ignoredFromInbox...) hace que FastAPI devuelva 422 antes de que
# este código vea el payload. Nunca una omisión tácita.


class LibrarySongIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    songId: str = Field(min_length=1, max_length=128)
    title: str = Field(min_length=1, max_length=512)
    artist: str = Field(default="", max_length=512)
    album: str | None = Field(default=None, max_length=512)
    durationSeconds: int | None = Field(default=None, ge=0)
    fileHash: str | None = Field(default=None, max_length=128)
    hashKind: str | None = Field(default=None, max_length=32)


class LibraryPlaylistIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    playlistId: str = Field(min_length=1, max_length=128)
    name: str = Field(min_length=1, max_length=256)
    sortOrder: int = 0


class LibraryPlaylistSongIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    playlistId: str = Field(min_length=1, max_length=128)
    songId: str = Field(min_length=1, max_length=128)
    orderIndex: int = 0


class LibraryPushPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    baseVersion: int = Field(ge=0)
    contentHash: str | None = None
    songs: list[LibrarySongIn] = Field(default_factory=list)
    playlists: list[LibraryPlaylistIn] = Field(default_factory=list)
    playlistSongs: list[LibraryPlaylistSongIn] = Field(default_factory=list)


class HistoryRowIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    songId: str = Field(min_length=1, max_length=128)
    playedAtLocal: str  # ISO 8601 sin huso, tal cual lo grabó el cliente — es la clave de dedupe
    playedAtUtc: str  # ISO 8601 con huso — el instante normalizado que usan las consultas
    playSeconds: int = 0


class HistoryPushPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    rows: list[HistoryRowIn] = Field(default_factory=list)
    # El desfase horario de quien sube, para que week_start_utc calcule el
    # "lunes" en el huso correcto de esta cuenta (A5) — se refresca en
    # users.utc_offset_minutes desde aquí, no desde /stats/me, porque el
    # cliente sube historial mucho más seguido que lo que consulta sus
    # propias estadísticas.
    utcOffsetMinutes: int | None = None


# --- Funciones puras ---------------------------------------------------


_WHITESPACE_RE = re.compile(r"\s+")


def compute_artist_key(artist: str) -> str:
    """`strip` → colapsar espacios → `casefold`. Se calcula al SUBIR, no al
    leer: mueve el trabajo del camino de lectura (el perfil de un amigo, que
    debe ir rápido) al de escritura. No intenta separar "A feat. B" — el
    cliente tampoco lo hace, y la coherencia con la pantalla local vale más
    que una agrupación más lista."""
    return _WHITESPACE_RE.sub(" ", artist.strip()).casefold()


def week_start_utc(now_utc: datetime.datetime, utc_offset_minutes: int) -> datetime.datetime:
    """Lunes 00:00 en el huso de la cuenta MIRADA, no del que mira — "las
    más escuchadas de Ana esta semana" usa el lunes de Ana. Réplica a
    propósito de `_getStartOfWeek()` (database_helper.dart) — arreglarla sólo
    acá haría que las estadísticas propias (SQLite local) y la vista que un
    amigo tiene de esas mismas estadísticas dieran números distintos."""
    offset = datetime.timedelta(minutes=utc_offset_minutes)
    local_now = now_utc + offset
    monday_local = (local_now - datetime.timedelta(days=local_now.weekday())).replace(
        hour=0, minute=0, second=0, microsecond=0
    )
    return monday_local - offset


def month_window_start_utc(now_utc: datetime.datetime) -> datetime.datetime:
    """Ventana deslizante de 30 días, sin huso — réplica a propósito de
    `database_helper.dart:1012`. Ver week_start_utc: la misma razón para no
    "arreglarlo" en un solo lado."""
    return now_utc - datetime.timedelta(days=30)


def period_start_utc(period: str, now_utc: datetime.datetime, utc_offset_minutes: int) -> datetime.datetime:
    if period == "week":
        return week_start_utc(now_utc, utc_offset_minutes)
    return month_window_start_utc(now_utc)


MAX_PLAY_SECONDS = 86_400


def sanitize_play_seconds(seconds: int) -> int | None:
    """`play_seconds` es entrada sin verificar: un cliente modificado puede
    declarar 10⁹ segundos para encabezar el tiempo de escucha frente a sus
    amigos. Se recorta a 24h; un valor negativo se descarta entero (None)."""
    if seconds < 0:
        return None
    return min(seconds, MAX_PLAY_SECONDS)


@dataclasses.dataclass
class SanitizedHistory:
    accepted: list[HistoryRowIn]
    skipped_invalid: int
    skipped_too_old: int
    skipped_duplicate_in_batch: int


def sanitize_history_rows(
    rows: list[HistoryRowIn],
    *,
    now: datetime.datetime,
    backfill_max_days: int = 0,
) -> SanitizedHistory:
    """Sanea y deduplica UNA subida antes de tocar la base:

    - fechas a más de 1 día en el futuro o 10 años en el pasado se descartan
      (`skipped_invalid`);
    - si `backfill_max_days > 0`, filas más viejas que eso se descartan
      también, contadas aparte (`skipped_too_old`) para que el cliente sepa
      que no debe reintentarlas;
    - `play_seconds` negativo descarta la fila entera;
    - una clave (songId, playedAtLocal) repetida DENTRO del mismo lote se
      deduplica aquí — Postgres lanza "cannot affect row a second time" si
      `ON CONFLICT DO UPDATE` ve la misma clave dos veces en una sentencia, y
      un cliente correcto nunca lo produce, pero un payload malformado no
      debe convertirse en un 500."""
    accepted: list[HistoryRowIn] = []
    seen: set[tuple[str, str]] = set()
    skipped_invalid = 0
    skipped_too_old = 0
    skipped_duplicate = 0

    max_future = now + datetime.timedelta(days=1)
    min_past = now - datetime.timedelta(days=365 * 10)
    backfill_cutoff = now - datetime.timedelta(days=backfill_max_days) if backfill_max_days > 0 else None

    for row in rows:
        try:
            played_at = datetime.datetime.fromisoformat(row.playedAtUtc)
        except ValueError:
            skipped_invalid += 1
            continue
        if played_at.tzinfo is None:
            played_at = played_at.replace(tzinfo=datetime.timezone.utc)
        if played_at > max_future or played_at < min_past:
            skipped_invalid += 1
            continue
        if backfill_cutoff is not None and played_at < backfill_cutoff:
            skipped_too_old += 1
            continue
        seconds = sanitize_play_seconds(row.playSeconds)
        if seconds is None:
            skipped_invalid += 1
            continue

        key = (row.songId, row.playedAtLocal)
        if key in seen:
            skipped_duplicate += 1
            continue
        seen.add(key)
        accepted.append(row.model_copy(update={"playSeconds": seconds}))

    return SanitizedHistory(accepted, skipped_invalid, skipped_too_old, skipped_duplicate)


# --- Almacenamiento en Postgres --------------------------------------------


class LibraryStore:
    def __init__(self, pool: asyncpg.Pool) -> None:
        self._pool = pool

    async def create_table(self) -> None:
        async with self._pool.acquire() as conn:
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS library_songs (
                    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    song_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    artist TEXT NOT NULL DEFAULT '',
                    artist_key TEXT NOT NULL DEFAULT '',
                    album TEXT,
                    duration_seconds INTEGER,
                    file_hash TEXT,
                    hash_kind TEXT,
                    PRIMARY KEY (user_id, song_id)
                )
                """
            )
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS library_playlists (
                    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    playlist_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (user_id, playlist_id)
                )
                """
            )
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS library_playlist_songs (
                    user_id BIGINT NOT NULL,
                    playlist_id TEXT NOT NULL,
                    song_id TEXT NOT NULL,
                    order_index INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (user_id, playlist_id, song_id)
                )
                """
                # Sin FK contra library_songs, a propósito (A2 del plan): si
                # la tuviera, un push que omite una canción por error
                # arrastraría en cascada su pertenencia a la playlist. Se
                # deja colgando y se filtra con JOIN al leer.
            )
            await conn.execute(
                """
                CREATE TABLE IF NOT EXISTS play_history (
                    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    song_id TEXT NOT NULL,
                    played_at_local TEXT NOT NULL,
                    played_at TIMESTAMPTZ NOT NULL,
                    play_seconds INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (user_id, song_id, played_at_local)
                )
                """
            )
            await conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_play_history_user_played_at ON play_history(user_id, played_at)"
            )

    async def get_library(self, user_id: int) -> dict:
        async with self._pool.acquire() as conn:
            songs = await conn.fetch(
                "SELECT song_id, title, artist, album, duration_seconds, file_hash, hash_kind "
                "FROM library_songs WHERE user_id = $1",
                user_id,
            )
            playlists = await conn.fetch(
                "SELECT playlist_id, name, sort_order FROM library_playlists WHERE user_id = $1",
                user_id,
            )
            playlist_songs = await conn.fetch(
                "SELECT playlist_id, song_id, order_index FROM library_playlist_songs WHERE user_id = $1",
                user_id,
            )
        return {
            "songs": [dict(r) for r in songs],
            "playlists": [dict(r) for r in playlists],
            "playlistSongs": [dict(r) for r in playlist_songs],
        }

    async def push_library(self, user_id: int, payload: LibraryPushPayload) -> None:
        """Reemplaza el índice completo de `user_id` por el del payload,
        combinando por clave (upsert + delete de lo ausente), nunca "borrar
        todo e insertar todo" — eso sería *churn* gratuito contra el plan
        gratuito de Neon en cada sincronización.

        Se asume que quien llama ya resolvió la versión optimista (ver
        accounts.bump_library_version) y el atajo por contentHash antes de
        invocar esto."""
        song_ids = [s.songId for s in payload.songs]
        playlist_ids = [p.playlistId for p in payload.playlists]

        async with self._pool.acquire() as conn:
            async with conn.transaction():
                if payload.songs:
                    await conn.execute(
                        """
                        INSERT INTO library_songs
                            (user_id, song_id, title, artist, artist_key, album, duration_seconds, file_hash, hash_kind)
                        SELECT $1, s, t, a, ak, al, d, fh, hk
                        FROM unnest($2::text[], $3::text[], $4::text[], $5::text[], $6::text[], $7::int[], $8::text[], $9::text[])
                            AS u(s, t, a, ak, al, d, fh, hk)
                        ON CONFLICT (user_id, song_id) DO UPDATE SET
                            title = excluded.title, artist = excluded.artist, artist_key = excluded.artist_key,
                            album = excluded.album, duration_seconds = excluded.duration_seconds,
                            file_hash = excluded.file_hash, hash_kind = excluded.hash_kind
                        WHERE (library_songs.*) IS DISTINCT FROM (excluded.*)
                        """,
                        user_id,
                        song_ids,
                        [s.title for s in payload.songs],
                        [s.artist for s in payload.songs],
                        [compute_artist_key(s.artist) for s in payload.songs],
                        [s.album for s in payload.songs],
                        [s.durationSeconds for s in payload.songs],
                        [s.fileHash for s in payload.songs],
                        [s.hashKind for s in payload.songs],
                    )
                await conn.execute(
                    "DELETE FROM library_songs WHERE user_id = $1 AND NOT (song_id = ANY($2::text[]))",
                    user_id,
                    song_ids,
                )

                if payload.playlists:
                    await conn.execute(
                        """
                        INSERT INTO library_playlists (user_id, playlist_id, name, sort_order)
                        SELECT $1, p, n, so FROM unnest($2::text[], $3::text[], $4::int[]) AS u(p, n, so)
                        ON CONFLICT (user_id, playlist_id) DO UPDATE SET
                            name = excluded.name, sort_order = excluded.sort_order
                        WHERE (library_playlists.*) IS DISTINCT FROM (excluded.*)
                        """,
                        user_id,
                        playlist_ids,
                        [p.name for p in payload.playlists],
                        [p.sortOrder for p in payload.playlists],
                    )
                await conn.execute(
                    "DELETE FROM library_playlists WHERE user_id = $1 AND NOT (playlist_id = ANY($2::text[]))",
                    user_id,
                    playlist_ids,
                )

                # library_playlist_songs se reemplaza entero: es una tabla de
                # pertenencia pura (playlist, canción, orden), sin más
                # columnas que combinar por clave — borrar e insertar de
                # nuevo es tan barato como diferenciarla fila a fila.
                await conn.execute("DELETE FROM library_playlist_songs WHERE user_id = $1", user_id)
                if payload.playlistSongs:
                    await conn.executemany(
                        """
                        INSERT INTO library_playlist_songs (user_id, playlist_id, song_id, order_index)
                        VALUES ($1, $2, $3, $4)
                        """,
                        [(user_id, ps.playlistId, ps.songId, ps.orderIndex) for ps in payload.playlistSongs],
                    )

    async def push_history(self, user_id: int, rows: list[HistoryRowIn]) -> int:
        """Inserción por `unnest`, no `executemany` (N ejecuciones) ni
        `copy_records_to_table` (no admite ON CONFLICT) — a la escala de una
        migración masiva (20k-50k filas) la forma del INSERT decide si tarda
        segundos o minutos. `ON CONFLICT DO NOTHING` es la idempotencia
        entera: la clave natural (song_id, played_at_local) ya sale de datos
        que el cliente tiene, así que reintentar un lote es inocuo."""
        if not rows:
            return 0
        async with self._pool.acquire() as conn:
            result = await conn.fetch(
                """
                INSERT INTO play_history (user_id, song_id, played_at_local, played_at, play_seconds)
                SELECT $1, s, l, t, sec
                FROM unnest($2::text[], $3::text[], $4::timestamptz[], $5::int[]) AS u(s, l, t, sec)
                ON CONFLICT DO NOTHING
                RETURNING 1
                """,
                user_id,
                [r.songId for r in rows],
                [r.playedAtLocal for r in rows],
                [r.playedAtUtc for r in rows],
                [r.playSeconds for r in rows],
            )
        return len(result)

    async def has_library(self, user_id: int) -> bool:
        async with self._pool.acquire() as conn:
            return bool(
                await conn.fetchval("SELECT EXISTS(SELECT 1 FROM library_songs WHERE user_id = $1)", user_id)
            )

    async def get_titles(self, pairs: list[tuple[int, str]]) -> dict[tuple[int, str], str]:
        """Resuelve título contra el índice DE QUIEN PUBLICA — nunca contra
        el de quien mira. `pairs` es (user_id, song_id); usado para "escuchando
        ahora" de una lista de amigos en una sola consulta, nunca N."""
        if not pairs:
            return {}
        async with self._pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT ls.user_id, ls.song_id, ls.title
                FROM library_songs ls
                JOIN unnest($1::bigint[], $2::text[]) AS u(user_id, song_id)
                    ON ls.user_id = u.user_id AND ls.song_id = u.song_id
                """,
                [p[0] for p in pairs],
                [p[1] for p in pairs],
            )
        return {(r["user_id"], r["song_id"]): r["title"] for r in rows}

    async def prune_old_history(self, user_id: int, retention_days: int) -> None:
        """Poda oportunista: como mucho una vez por subida, nunca una tarea
        periódica — Render puede dormir el proceso, así que no hay ningún
        momento garantizado en el que un cron corra."""
        if retention_days <= 0:
            return
        cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=retention_days)
        async with self._pool.acquire() as conn:
            await conn.execute(
                "DELETE FROM play_history WHERE user_id = $1 AND played_at < $2", user_id, cutoff
            )

    async def get_stats(
        self,
        user_id: int,
        *,
        period_start_utc: datetime.datetime,
    ) -> dict:
        """Totales sin JOIN; tops con INNER JOIN library_songs (una canción
        sin metadatos no se puede mostrar). Consecuencia a documentar, no
        confundir con un fallo: `totalPlays` puede superar la suma de los
        `playCount` del top."""
        async with self._pool.acquire() as conn:
            total_plays = await conn.fetchval(
                "SELECT COUNT(*) FROM play_history WHERE user_id = $1 AND played_at >= $2",
                user_id,
                period_start_utc,
            )
            total_seconds = await conn.fetchval(
                "SELECT COALESCE(SUM(play_seconds), 0) FROM play_history WHERE user_id = $1 AND played_at >= $2",
                user_id,
                period_start_utc,
            )
            top_songs = await conn.fetch(
                """
                SELECT h.song_id AS "songId", ls.title, ls.artist, COUNT(*) AS "playCount"
                FROM play_history h
                INNER JOIN library_songs ls ON ls.user_id = h.user_id AND ls.song_id = h.song_id
                WHERE h.user_id = $1 AND h.played_at >= $2
                GROUP BY h.song_id, ls.title, ls.artist
                ORDER BY "playCount" DESC
                LIMIT 10
                """,
                user_id,
                period_start_utc,
            )
            top_artists = await conn.fetch(
                """
                SELECT mode() WITHIN GROUP (ORDER BY ls.artist) AS artist,
                       COUNT(*) AS "playCount"
                FROM play_history h
                INNER JOIN library_songs ls ON ls.user_id = h.user_id AND ls.song_id = h.song_id
                WHERE h.user_id = $1 AND h.played_at >= $2 AND ls.artist_key <> ''
                GROUP BY ls.artist_key
                ORDER BY "playCount" DESC
                LIMIT 10
                """,
                user_id,
                period_start_utc,
            )
        # Nombres de campo en camelCase a propósito: es el mismo contrato que
        # StatisticsData.fromMap/TopArtistStat.fromMap/TopSongStat.fromMap ya
        # esperan del lado del cliente (ver lib/models/statistics_data.dart) —
        # esas estadísticas de un amigo se pintan con el MISMO StatisticsView
        # que las propias, así que el shape tiene que calzar exacto.
        return {
            "totalPlays": total_plays or 0,
            "totalListenSeconds": total_seconds or 0,
            "topSongs": [dict(r) for r in top_songs],
            "topArtists": [dict(r) for r in top_artists],
        }
