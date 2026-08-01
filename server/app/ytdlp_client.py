"""Envoltura de yt-dlp: resolver metadata, expandir playlists, buscar y bajar audio.

yt-dlp se usa como librería, no por subprocess: los errores llegan como
excepciones tipadas en vez de haber que parsear stderr, y no hay un proceso
por petición.
"""
import logging
import threading
from pathlib import Path

import yt_dlp
from yt_dlp.utils import DownloadError, ExtractorError, UnsupportedError

from . import cache, config

log = logging.getLogger(__name__)

# Solo AAC en contenedor MP4, nunca recodificado (DD4). Es el formato que la
# app ya sabe indexar (`m4a` está en AudioIdentityService.audioExtensions) y
# cuyos tags sabe escribir audio_metadata_reader. Si un vídeo no tiene pista
# AAC, es preferible fallar con un mensaje claro que devolver un WebM que el
# cliente rechazaría por extensión más adelante.
AUDIO_FORMAT = "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]"

# Un candado por vídeo, para que dos peticiones simultáneas del mismo id no
# lo descarguen dos veces (gastando el doble de presupuesto de IP).
_video_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


class NoAudioTrackError(Exception):
    """El vídeo existe pero no ofrece ninguna pista AAC/M4A."""


class ExtractionError(Exception):
    """yt-dlp no pudo extraer: vídeo privado, borrado, bloqueado por región…"""


def _lock_for(video_id: str) -> threading.Lock:
    with _locks_guard:
        return _video_locks.setdefault(video_id, threading.Lock())


def _base_opts() -> dict:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "skip_download": True,
        "extract_flat": False,
        # El sidecar que genera PO Tokens. Sin esto, YouTube devuelve 403 en
        # la mayoría de clientes desde 2025.
        "extractor_args": {
            "youtubepot-bgutilhttp": {"base_url": [config.POT_PROVIDER_URL]},
        },
    }
    if config.COOKIES_FILE:
        opts["cookiefile"] = config.COOKIES_FILE
    return opts


def _clean_artist(info: dict) -> str:
    """Artista real si YouTube lo da, si no el canal sin el sufijo ' - Topic'.

    Los canales autogenerados de YouTube Music se llaman "<Artista> - Topic";
    dejarlo tal cual mete ese sufijo en los tags de todos los archivos.
    """
    artist = info.get("artist") or info.get("creator")
    if artist:
        return str(artist).split(",")[0].strip()
    channel = info.get("uploader") or info.get("channel") or ""
    if channel.endswith(" - Topic"):
        channel = channel[: -len(" - Topic")]
    return channel.strip() or "Desconocido"


def _to_track(info: dict) -> dict:
    """Normaliza la salida de yt-dlp al DTO que consume la app."""
    video_id = info.get("id") or ""
    return {
        "id": video_id,
        "title": (info.get("track") or info.get("title") or "").strip() or video_id,
        "artist": _clean_artist(info),
        "album": (info.get("album") or None),
        "durationSeconds": int(info.get("duration") or 0),
        "thumbnailUrl": info.get("thumbnail") or "",
        "sourceUrl": info.get("webpage_url") or f"https://www.youtube.com/watch?v={video_id}",
    }


def _extract(url: str, opts: dict) -> dict:
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
    except UnsupportedError as e:
        raise ExtractionError(f"URL no soportada: {e}") from e
    except (DownloadError, ExtractorError) as e:
        raise ExtractionError(str(e)) from e
    if info is None:
        raise ExtractionError("yt-dlp no devolvió información para esa URL")
    return info


def resolve(url: str) -> dict:
    """Metadata de un vídeo suelto. `noplaylist` para que una URL de vídeo
    dentro de una playlist devuelva el vídeo, no la playlist entera."""
    opts = _base_opts() | {"noplaylist": True}
    info = _extract(url, opts)
    if info.get("_type") == "playlist":
        entries = [e for e in (info.get("entries") or []) if e]
        if not entries:
            raise ExtractionError("La URL es una playlist vacía")
        info = entries[0]
    return _to_track(info)


def resolve_playlist(url: str) -> dict:
    """Expande una playlist. `extract_flat` evita una petición por vídeo, que
    con 50 pistas quemaría el presupuesto de IP antes de bajar nada."""
    opts = _base_opts() | {
        "noplaylist": False,
        "extract_flat": "in_playlist",
        "playlistend": config.MAX_PLAYLIST_ENTRIES,
    }
    info = _extract(url, opts)
    raw_entries = [e for e in (info.get("entries") or []) if e]
    if not raw_entries:
        raise ExtractionError("La playlist no tiene vídeos accesibles")

    entries = []
    for entry in raw_entries:
        # Los vídeos privados o borrados aparecen como entradas sin duración
        # ni título utilizable; se omiten en vez de encolarse para fallar.
        if not entry.get("id"):
            continue
        entries.append(_to_track(entry))

    return {
        "id": info.get("id") or "",
        "name": (info.get("title") or "Playlist").strip(),
        "sourceUrl": info.get("webpage_url") or url,
        "entries": entries,
    }


def search(query: str, limit: int) -> list[dict]:
    limit = max(1, min(limit, config.MAX_SEARCH_RESULTS))
    opts = _base_opts() | {"noplaylist": True, "extract_flat": "in_playlist"}
    info = _extract(f"ytsearch{limit}:{query}", opts)
    return [_to_track(e) for e in (info.get("entries") or []) if e and e.get("id")]


def fetch_audio(video_id: str) -> Path:
    """Devuelve la ruta local del M4A, bajándolo si no está cacheado."""
    cached = cache.get(video_id)
    if cached is not None:
        return cached

    with _lock_for(video_id):
        # Otra petición pudo haberlo bajado mientras esperábamos el candado.
        cached = cache.get(video_id)
        if cached is not None:
            return cached

        config.CACHE_DIR.mkdir(parents=True, exist_ok=True)
        target = cache.path_for(video_id)
        # Se baja a un temporal y se renombra al final, para que una descarga
        # interrumpida nunca deje un archivo truncado que el cache dé por
        # bueno en la siguiente petición.
        partial = target.with_suffix(".part-download")

        opts = _base_opts() | {
            "skip_download": False,
            "noplaylist": True,
            "format": AUDIO_FORMAT,
            "outtmpl": str(partial),
            "overwrites": True,
        }

        url = f"https://www.youtube.com/watch?v={video_id}"
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                ydl.download([url])
        except (DownloadError, ExtractorError) as e:
            partial.unlink(missing_ok=True)
            message = str(e)
            if "Requested format is not available" in message:
                raise NoAudioTrackError(
                    "El vídeo no ofrece ninguna pista de audio AAC/M4A"
                ) from e
            raise ExtractionError(message) from e

        if not partial.is_file() or partial.stat().st_size == 0:
            partial.unlink(missing_ok=True)
            raise ExtractionError("yt-dlp terminó sin producir un archivo de audio")

        partial.replace(target)
        cache.evict_if_needed()
        return target


def version() -> str:
    return getattr(yt_dlp.version, "__version__", "desconocida")
