"""Envoltura de yt-dlp: resolver metadata, expandir playlists, buscar y bajar audio.

yt-dlp se usa como librería, no por subprocess: los errores llegan como
excepciones tipadas en vez de haber que parsear stderr, y no hay un proceso
por petición.
"""
import logging
import subprocess
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


# Cualquier fallo que NO venga de yt-dlp mismo. El caso que lo motivó, visto en
# producción: el proveedor de PO tokens en "script mode" lanza un proceso Node
# por token y antes comprueba que responde (`node generate_once.js --version`),
# con un plazo de 15 s que el plugin fija por su cuenta. En un plan gratuito con
# ~0,1 vCPU, arrancar Node no entra en ese plazo, y `subprocess.TimeoutExpired`
# no es una excepción de yt-dlp: subía sin traducir hasta FastAPI y el cliente
# recibía un 500 opaco sobre un vídeo perfectamente sano.
#
# Se tratan como TEMPORALES a propósito: describen un servidor que no da
# abasto, no un vídeo imposible. La cola reintenta, que es lo correcto.
_ENVIRONMENT_ERRORS = (subprocess.TimeoutExpired, subprocess.SubprocessError, OSError)


class NoAudioTrackError(Exception):
    """El vídeo existe pero no ofrece ninguna pista AAC/M4A."""


class ExtractionError(Exception):
    """Fallo TEMPORAL: la IP está bloqueada, la red falló, YouTube tosió.

    Reintentar más tarde tiene sentido. Sale como HTTP 502.
    """


class PermanentlyUnavailableError(Exception):
    """Fallo DEFINITIVO para esa URL: vídeo borrado, privado, URL inválida.

    Reintentar no puede funcionar nunca, así que sale como HTTP 404 y el
    cliente lo saca de la cola en vez de gastar su presupuesto de reintentos.

    Deliberadamente NO hereda de [ExtractionError]: si lo hiciera, un
    `except ExtractionError` lo atraparía primero y volvería a colapsar los
    dos casos en un 502, que es justo lo que esto viene a separar.
    """


class AntiBotBlockError(ExtractionError):
    """El muro anti-bot de YouTube específicamente ("sign in to confirm
    you're not a bot"), no un 502 genérico.

    Sigue siendo temporal — por eso SÍ hereda de [ExtractionError], a
    diferencia de [PermanentlyUnavailableError]: todo lo que ya atrapa
    `EXTRACTION_ERRORS` lo sigue haciendo sin tocar nada. La diferencia es la
    ventana de recuperación: `docs/investigacion_muro_antibot.md` la mide en
    **20-40+ minutos**, no los segundos que basta esperar tras un corte de
    red cualquiera. Sale como HTTP 503 (no 502) para que el cliente pueda
    darle un trato distinto — esperar de verdad, no gastar su presupuesto de
    reintentos cortos en algo que no va a despejarse en 45 segundos.
    """


#: Para capturar ambos de una vez donde el manejo es común. AntiBotBlockError
#: ya cae en ExtractionError, así que no hace falta nombrarlo aparte aquí.
EXTRACTION_ERRORS = (ExtractionError, PermanentlyUnavailableError)

# Frase con la que yt-dlp señala el muro anti-bot específicamente. Se compara
# en minúsculas, igual que _PERMANENT_MARKERS.
_ANTIBOT_MARKER = "sign in to confirm you're not a bot"

# Frases con las que yt-dlp señala que el problema es del vídeo y no del
# momento. Se comparan en minúsculas contra el mensaje completo.
#
# Ojo con lo que NO está aquí: "sign in to confirm you're not a bot" es un
# bloqueo de IP, o sea temporal (ver _ANTIBOT_MARKER arriba), y meterlo en
# esta lista haría que la cola descartara canciones perfectamente
# descargables. Es justo el error que más se parece a uno permanente sin
# serlo.
#
# "video unavailable" / "this video is unavailable" SÍ están abajo, con
# historia: se sacaron el 2026-08-22 pensando que era un falso positivo
# transitorio del proveedor de PO Tokens bajo carga, y se repusieron el mismo
# día tras investigar más — no es transitorio. Es el bloqueo de YouTube a
# nivel de CONTENIDO sobre los tracks de canales auto-generados "- Topic"
# (audio oficial con licencia): reintentar el MISMO vídeo 20 veces seguidas
# en 8 minutos falló las 20, con los 6 tipos de cliente que prueba yt-dlp
# (visionos/web/android/ios/tv/web_embedded), y confirmado contra la API de
# YouTube directamente sin este servidor de por medio. Medido contra una
# playlist real de 68 vídeos: 36 de 37 tracks "- Topic" fallaron así; 0 de 31
# "Music Clip" del mismo canal. El arreglo real vive del lado del cliente
# (`DownloadProvider._tryFallbackSearch`, lib/providers/download_provider.dart):
# cuando un vídeo da por perdido sus reintentos, busca el mismo tema por
# artista+título y sustituye por un candidato de duración parecida — casi
# siempre el "Music Clip" oficial existe. Clasificarlo aquí como permanente
# (404, sin gastar reintentos) es lo que hace que ese fallback se dispare
# rápido en vez de esperar ~65s de reintentos inútiles contra el mismo id.
_PERMANENT_MARKERS = (
    "video unavailable",
    "this video is unavailable",
    "private video",
    "this video is private",
    "has been removed",
    "removed by the uploader",
    "account associated with this video has been terminated",
    "does not exist",
    "incomplete youtube id",
    "unsupported url",
    "is not a valid url",
    "no video formats found",
    "members-only",
    "join this channel",
    "confirm your age",
    "age-restricted",
    "video is not available in your country",
    "blocked it in your country",
)


def _classify(message: str) -> Exception:
    """Convierte el mensaje de yt-dlp en la excepción del tipo correcto."""
    lowered = message.lower()
    for marker in _PERMANENT_MARKERS:
        if marker in lowered:
            return PermanentlyUnavailableError(message)
    if _ANTIBOT_MARKER in lowered:
        return AntiBotBlockError(message)
    return ExtractionError(message)


def _environment_message(error: Exception) -> str:
    """Texto para un fallo de ENTORNO, no de vídeo. Nombra la causa probable
    en vez de dejar un mensaje genérico: el sitio donde esto se descubrió fue
    un traceback en producción, y el cliente no tenía forma de saber que el
    problema no era la canción que había pedido."""
    if isinstance(error, subprocess.TimeoutExpired):
        return (
            "el proveedor de PO tokens no respondió a tiempo: este servidor no "
            "da abasto para arrancarlo (típico de un plan con poca CPU)"
        )
    return f"fallo del entorno del servidor: {type(error).__name__}"


def classify_missing_aac(formats: list[dict]) -> str:
    """Por qué no había pista AAC: `"no_audio"` o `"degraded"`.

    La distinción no es cosmética, decide si el trabajo se descarta para
    siempre o se reintenta. `"Requested format is not available"` tiene dos
    causas que no se parecen en nada:

    - El vídeo de verdad no trae audio AAC (raro, pero existe). Definitivo:
      reintentar no puede cambiarlo nunca.
    - YouTube nos devolvió una lista de formatos RECORTADA. Le pasa a una IP
      de datacenter cuando la sesión no vale — cookies caducadas, sin PO
      token válido. El vídeo tiene su AAC perfectamente; a nosotros no nos lo
      ofrecen. Es un problema del servidor, temporal, y arreglarlo es
      renovar la sesión.

    Tratar el segundo caso como el primero es lo caro: 415 no es reintentable
    en el cliente (`download_source.dart`, `isRetryable`), así que una sesión
    caducada haría que la cola descartara en silencio la tanda entera con un
    veredicto definitivo y falso — "este vídeo no tiene audio compatible" —
    sobre canciones que están perfectamente bien.

    La señal es simple: si hay formatos con audio pero ninguno AAC, la lista
    viene recortada. Un vídeo real de YouTube ofrece ambos.
    """
    has_audio = False
    for f in formats:
        acodec = (f.get("acodec") or "none").lower()
        if acodec == "none":
            continue
        has_audio = True
        if acodec.startswith("mp4a") or (f.get("ext") or "").lower() == "m4a":
            # Había AAC y aun así falló la selección: no es "el vídeo no
            # tiene audio", así que se trata como temporal igual.
            return "degraded"
    return "degraded" if has_audio else "no_audio"


def _missing_aac_error(url: str) -> Exception:
    """Vuelve a pedir la lista de formatos (sólo metadata, sin descargar) para
    decidir cuál de las dos causas fue. Si esa segunda consulta también falla,
    se asume lo temporal: equivocarse hacia el reintento cuesta una petición;
    equivocarse hacia lo definitivo tira la canción para siempre."""
    try:
        info = _extract(url, _base_opts() | {"skip_download": True, "noplaylist": True})
        verdict = classify_missing_aac(info.get("formats") or [])
    except Exception:  # noqa: BLE001
        verdict = "degraded"

    if verdict == "no_audio":
        return NoAudioTrackError("El vídeo no ofrece ninguna pista de audio AAC/M4A")
    return ExtractionError(
        "YouTube no está ofreciendo audio AAC a este servidor: la lista de "
        "formatos vino recortada. Suele significar que la sesión de cookies "
        "caducó o que la IP está limitada"
    )


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
        # Sin esto, yt-dlp carga ~1800 extractores incluido el genérico
        # (GenericIE), que hace fetch de CUALQUIER URL http(s) — un cliente
        # autenticado podría usar /resolve o /playlist como proxy SSRF hacia
        # la red local del servidor (router, otros peers de Tailscale, el
        # propio proveedor de PO Tokens en loopback). Restringir a los
        # extractores de YouTube cierra esa vía sin tocar la validación de
        # host, que es la otra mitad del arreglo.
        # Regex, no nombres exactos, para no romperse si yt-dlp renombra
        # extractores en una actualización futura.
        "allowed_extractors": ["youtube.*"],
        # Quien genera los PO Tokens. Sin esto, YouTube devuelve 403 en la
        # mayoría de clientes desde 2025. Dos implementaciones posibles del
        # mismo proveedor, y hay que elegir UNA: el sidecar HTTP siempre
        # encendido (por defecto, más rápido) o el script invocado por token
        # (para plataformas que sólo dan un servicio). Ver POT_PROVIDER_SCRIPT_HOME.
        "extractor_args": {
            "youtubepot-bgutilscript": {"server_home": [config.POT_PROVIDER_SCRIPT_HOME]},
        }
        if config.POT_PROVIDER_SCRIPT_HOME
        else {
            "youtubepot-bgutilhttp": {"base_url": [config.POT_PROVIDER_URL]},
        },
        # yt-dlp solo habilita "deno" por defecto para el desafío de firma
        # ("n challenge"). Node ya es un requisito de instalación (el
        # proveedor de PO Tokens es una app Node, ver server/README.md), así
        # que se añade como runtime en vez de pedir instalar Deno aparte.
        # Sin esto (y sin el paquete yt-dlp-ejs en requirements.txt, que trae
        # el script que este runtime ejecuta) yt-dlp no puede resolver la
        # firma y el síntoma es 403 en /audio con /resolve funcionando bien
        # — el aviso real queda silenciado porque el servidor corre con
        # quiet=True.
        "js_runtimes": {"deno": {}, "node": {}},
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
        raise PermanentlyUnavailableError(f"URL no soportada: {e}") from e
    except (DownloadError, ExtractorError) as e:
        raise _classify(str(e)) from e
    except _ENVIRONMENT_ERRORS as e:
        raise ExtractionError(_environment_message(e)) from e
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
                raise _missing_aac_error(url) from e
            raise _classify(message) from e
        except _ENVIRONMENT_ERRORS as e:
            partial.unlink(missing_ok=True)
            raise ExtractionError(_environment_message(e)) from e

        if not partial.is_file() or partial.stat().st_size == 0:
            partial.unlink(missing_ok=True)
            raise ExtractionError("yt-dlp terminó sin producir un archivo de audio")

        partial.replace(target)
        cache.evict_if_needed()
        return target


def version() -> str:
    return getattr(yt_dlp.version, "__version__", "desconocida")
