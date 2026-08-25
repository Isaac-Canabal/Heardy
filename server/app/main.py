"""API HTTP que Heardy consume para importar audio a la biblioteca local.

Ver ../README.md para despliegue y CLAUDE.md (DD1) para por qué existe este
servicio en vez de un extractor embebido en la app.
"""
import asyncio
import datetime
import logging
import os
import re
import shutil
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlparse

import asyncpg
import httpx
from fastapi import Depends, FastAPI, HTTPException, Query, Request, status
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from pydantic import BaseModel, Field

from . import config, quota, ytdlp_client
from .auth import require_admin, resolve_identity
from .rate_limit import enforce_rate_limit

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("heardy")


def _prepare_writable_cookies() -> None:
    """Deja COOKIES_FILE apuntando a una copia ESCRIBIBLE, si hace falta.

    yt-dlp se usa con `with YoutubeDL(...)`, y su `__exit__` reescribe el
    archivo de cookies para guardar las que YouTube rota durante la sesión. Si
    el archivo es de solo lectura, esa escritura falla y la sesión se queda
    congelada en las cookies originales, que YouTube invalida enseguida.

    Es exactamente el caso de los "Secret Files" de Render (y del `secrets` de
    Docker/Kubernetes): se montan de solo lectura. Copiarlas a la caché las
    hace escribibles.

    Aviso que no se puede arreglar desde aquí: en un disco efímero la copia se
    pierde en cada reinicio y se vuelve a partir de las cookies originales, ya
    envejecidas. Con almacenamiento persistente esto no pasa.
    """
    if not config.COOKIES_FILE:
        return
    source = Path(config.COOKIES_FILE)
    if not source.is_file():
        log.warning("HEARDY_COOKIES_FILE apunta a %s, que no existe: se ignora", source)
        config.COOKIES_FILE = ""
        return
    if os.access(source, os.W_OK):
        log.info("cookies: %s (escribible)", source)
        return
    target = config.CACHE_DIR.parent / "cookies-rw.txt"
    try:
        shutil.copyfile(source, target)
        config.COOKIES_FILE = str(target)
        log.info("cookies: %s era de solo lectura, se usa la copia %s", source, target)
    except OSError as e:
        log.warning("no se pudo hacer una copia escribible de %s: %s", source, e)


_quota_pool: asyncpg.Pool | None = None
_quota_store: quota.QuotaStore | None = None


@asynccontextmanager
async def lifespan(_: FastAPI):
    global _quota_pool, _quota_store

    if not config.API_KEYS and not config.ALLOW_NO_AUTH:
        raise RuntimeError(
            "Falta HEARDY_API_KEY o HEARDY_API_KEYS. Generá una clave y ponela en "
            "server/.env, o arrancá con HEARDY_ALLOW_NO_AUTH=1 si solo escuchás en "
            "loopback. Ver server/README.md."
        )
    if config.DAILY_SONGS_PER_USER > 0 and not config.DATABASE_URL:
        # Mismo espíritu que el chequeo de arriba: un cupo diario sin
        # persistencia no es un cupo (hallazgo S3) — mejor no arrancar que
        # arrancar mintiendo que el límite existe.
        raise RuntimeError(
            "HEARDY_DAILY_SONGS_PER_USER está activo pero falta HEARDY_DATABASE_URL. "
            "El cupo diario necesita Postgres persistente (Neon) para sobrevivir un "
            "reinicio — ver server/README.md, sección 'Cupo diario'."
        )
    config.CACHE_DIR.mkdir(parents=True, exist_ok=True)
    _prepare_writable_cookies()

    if config.DAILY_SONGS_PER_USER > 0:
        _quota_pool = await asyncpg.create_pool(config.DATABASE_URL, min_size=1, max_size=5)
        store = quota.PostgresQuotaStore(_quota_pool)
        await store.create_table()
        _quota_store = store
        log.info("cupo diario: %s canciones/usuario, Postgres conectado", config.DAILY_SONGS_PER_USER)
    log.info("yt-dlp %s", ytdlp_client.version())
    log.info("proveedor de PO tokens: %s", config.POT_PROVIDER_URL)
    log.info("caché: %s", config.CACHE_DIR)
    log.info("claves de API configuradas: %s", ", ".join(config.API_KEYS.values()) or "ninguna")
    if config.RATE_LIMIT_PER_KEY > 0 or config.DAILY_QUOTA > 0:
        log.info(
            "rate limiting activo: %s peticiones/%ss por clave, %s/día en total",
            config.RATE_LIMIT_PER_KEY or "sin límite",
            config.RATE_LIMIT_WINDOW_SECONDS,
            config.DAILY_QUOTA or "sin límite",
        )
    if config.ALLOW_NO_AUTH:
        log.warning("autenticación DESACTIVADA (HEARDY_ALLOW_NO_AUTH=1)")
    if config.ENABLE_DOCS:
        log.warning("/docs y /openapi.json están expuestos (HEARDY_ENABLE_DOCS=1)")
    if not config.ADMIN_LABELS:
        log.warning(
            "HEARDY_ADMIN_LABELS vacío: DELETE /cache y GET /health/detail no los "
            "puede usar nadie hasta configurarlo"
        )
    try:
        yield
    finally:
        if _quota_pool is not None:
            await _quota_pool.close()


# /docs y /openapi.json quedan apagados salvo HEARDY_ENABLE_DOCS=1 (ver
# config.py) — expuestos sin autenticación, le dan a cualquiera el contrato
# exacto de la API gratis. Pasar None a openapi_url también apaga /docs por
# dentro (Swagger UI lo necesita para renderizar), así que hace falta el
# `if` en los dos, no sólo en docs_url.
app = FastAPI(
    title="Heardy download API",
    docs_url="/docs" if config.ENABLE_DOCS else None,
    redoc_url=None,
    openapi_url="/openapi.json" if config.ENABLE_DOCS else None,
    lifespan=lifespan,
)

# Limita las extracciones simultáneas. yt-dlp es bloqueante, así que además
# se ejecuta siempre en un hilo (`asyncio.to_thread`) para no congelar el
# bucle de eventos.
_extraction_semaphore = asyncio.Semaphore(config.MAX_CONCURRENT_EXTRACTIONS)

_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{5,32}$")

# Allowlist exacta de hosts, no blocklist de rangos IP: restringir los
# extractores de yt-dlp (ver ytdlp_client._base_opts) cierra la mitad "qué
# puede hacer yt-dlp" del SSRF, pero /resolve y /playlist seguían pudiendo
# recibir cualquier URL http(s) y pasársela sin mirar — confirmado en vivo
# contra http://127.0.0.1:4416/ping (el proveedor de PO Tokens, en el mismo
# host) antes de este cambio. Esta es la otra mitad: ninguna URL sale del
# proceso hacia una red que no sea la de YouTube.
#
# Deliberadamente sin resolución DNS ni validación de rangos IP: getaddrinfo
# es una llamada síncrona que bloquearía el bucle de eventos de FastAPI, y
# con una allowlist exacta de hosts es redundante — no hay ningún host de
# esta lista que pueda resolver a una IP privada de forma legítima.
_ALLOWED_URL_HOSTS = frozenset(
    {
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "youtu.be",
        "music.youtube.com",
        "youtube-nocookie.com",
        "www.youtube-nocookie.com",
    }
)


def is_allowed_youtube_url(url: str) -> tuple[bool, str]:
    """(permitida, motivo). El motivo es solo para el log — nunca se manda
    al cliente, para no darle un oráculo que distinga "esquema malo" de
    "host no permitido" de "URL rota"."""
    try:
        parsed = urlparse(url)
    except ValueError as e:
        return False, f"URL no parseable: {e}"
    if parsed.scheme not in ("http", "https"):
        return False, f"esquema no permitido: {parsed.scheme!r}"
    host = (parsed.hostname or "").lower()
    if host not in _ALLOWED_URL_HOSTS:
        return False, f"host no permitido: {host!r}"
    return True, ""


class UrlRequest(BaseModel):
    url: str = Field(min_length=5, max_length=2048)


def _require_allowed_url(url: str) -> None:
    """Aborta con 400 si `url` no apunta a un host de YouTube permitido.

    Corre ANTES de cualquier llamada de red — ni yt-dlp ni httpx ven la URL
    si esto no la deja pasar."""
    allowed, reason = is_allowed_youtube_url(url)
    if not allowed:
        log.warning("URL rechazada (%s): %s", reason, url)
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="URL no válida")


async def _run(fn, *args):
    """Ejecuta una llamada bloqueante de yt-dlp fuera del bucle de eventos,
    respetando el límite de concurrencia."""
    async with _extraction_semaphore:
        return await asyncio.to_thread(fn, *args)


def _extraction_error(exc: Exception) -> HTTPException:
    """Traduce un fallo de extracción al código que el cliente sabe leer.

    La distinción importa: el cliente reintenta un 502 y descarta un 404. Si
    todo saliera como 502, una canción borrada de YouTube consumiría el
    presupuesto de reintentos entero de la cola en cada arranque de la app.

    El muro anti-bot (`AntiBotBlockError`) es un caso aparte dentro de lo
    reintentable: sale como 503, no 502, para que el cliente sepa que esto
    necesita minutos de espera real (20-40+, medido en
    docs/investigacion_muro_antibot.md) y no el reintento corto que basta
    para un 502 genérico.
    """
    if isinstance(exc, ytdlp_client.PermanentlyUnavailableError):
        return HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc))
    if isinstance(exc, ytdlp_client.AntiBotBlockError):
        return HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc))
    return HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail=str(exc))


async def _pot_provider_status() -> dict:
    pot_reachable = False
    pot_detail = "no comprobado"
    pot_target = config.POT_PROVIDER_URL
    if config.POT_PROVIDER_SCRIPT_HOME:
        # En script mode no hay nada a lo que hacer ping: el proveedor es un
        # subproceso que se levanta por token. Comprobar el HTTP igual daría
        # siempre "inalcanzable", y la app lo enseña como advertencia — un
        # falso positivo peor que no comprobar. Lo verificable acá es que el
        # script exista; que genere tokens sólo se sabe al descargar.
        script = Path(config.POT_PROVIDER_SCRIPT_HOME) / "build" / "generate_once.js"
        pot_target = str(script)
        pot_reachable = script.is_file()
        pot_detail = "script listo" if pot_reachable else "falta build/generate_once.js"
    else:
        try:
            async with httpx.AsyncClient(timeout=3.0) as client:
                response = await client.get(f"{config.POT_PROVIDER_URL}/ping")
                pot_reachable = response.status_code < 500
                pot_detail = f"HTTP {response.status_code}"
        except Exception as e:  # noqa: BLE001 — es un diagnóstico, cualquier fallo es informativo
            pot_detail = f"inalcanzable: {type(e).__name__}"
    return {
        "mode": "script" if config.POT_PROVIDER_SCRIPT_HOME else "http",
        "url": pot_target,
        "reachable": pot_reachable,
        "detail": pot_detail,
    }


@app.get("/health")
async def health() -> JSONResponse:
    """Diagnóstico. Sin autenticación a propósito: la app necesita poder
    distinguir 'servidor apagado' de 'clave incorrecta' antes de tener clave —
    es justo lo que `ytdlp_server_source.dart:probe()` hace con esta
    respuesta, así que cada campo de aquí abajo es uno que ese código lee.

    Deliberadamente NO lleva `rateLimiting` ni `cookies` (ver /health/detail):
    esos dos, sin autenticación, le dicen gratis a cualquiera si el servidor
    tiene límites puestos y si depende de una sesión de cookies — información
    de la que un abusador se beneficia y que un usuario normal probando su
    conexión no necesita."""
    return JSONResponse(
        {
            "status": "ok",
            "ytdlpVersion": ytdlp_client.version(),
            "authRequired": bool(config.API_KEYS) and not config.ALLOW_NO_AUTH,
            "potProvider": await _pot_provider_status(),
        }
    )


@app.get("/health/detail", dependencies=[Depends(require_admin)])
async def health_detail() -> JSONResponse:
    """Lo que /health ya no expone en abierto: estado de la caché, de las
    cookies y la configuración de límites. Sólo para quien administra el
    servidor — ver `config.ADMIN_LABELS`."""
    cached_files = len(list(config.CACHE_DIR.glob("*.m4a"))) if config.CACHE_DIR.is_dir() else 0
    return JSONResponse(
        {
            "cache": {"files": cached_files, "maxBytes": config.CACHE_MAX_BYTES},
            # No se expone el contenido ni la ruta completa, sólo si están activas.
            "cookies": {"enabled": bool(config.COOKIES_FILE)},
            "rateLimiting": {
                "perKeyLimit": config.RATE_LIMIT_PER_KEY,
                "perKeyWindowSeconds": config.RATE_LIMIT_WINDOW_SECONDS,
                "dailyQuota": config.DAILY_QUOTA,
            },
            # Fase 3 del plan de seguridad: cupo de CANCIONES por usuario,
            # distinto de dailyQuota de arriba (que cuenta peticiones — ver
            # app/quota.py). "connected" en false con dailyLimit > 0 sería el
            # estado roto que el chequeo del lifespan ya impide arrancar.
            "dailySongQuota": {
                "limitPerUser": config.DAILY_SONGS_PER_USER,
                "connected": _quota_store is not None,
            },
        }
    )


@app.post("/resolve")
async def resolve(body: UrlRequest, identity: str = Depends(enforce_rate_limit)) -> dict:
    _require_allowed_url(body.url)
    try:
        return await _run(ytdlp_client.resolve, body.url)
    except ytdlp_client.EXTRACTION_ERRORS as e:
        raise _extraction_error(e) from e
    finally:
        # D-4 (Fase 2 del plan de seguridad): identidad y URL/id NUNCA en la
        # misma línea de log. Con identidad real (Firebase, no ya una clave
        # compartida por todos), una sola línea con las dos cosas es
        # historial de escucha atribuible acumulándose en los logs de un
        # tercero (Render) — algo que nunca se decidió guardar a propósito.
        # El conteo por identidad sigue existiendo para diagnosticar
        # abuso/cuota; el detalle de qué se pidió sigue existiendo para
        # diagnosticar extracciones fallidas. Sólo dejan de viajar juntos.
        log.info("/resolve por %s", identity)
        log.info("/resolve: %s", body.url)


@app.post("/playlist")
async def playlist(body: UrlRequest, identity: str = Depends(enforce_rate_limit)) -> dict:
    _require_allowed_url(body.url)
    try:
        return await _run(ytdlp_client.resolve_playlist, body.url)
    except ytdlp_client.EXTRACTION_ERRORS as e:
        raise _extraction_error(e) from e
    finally:
        log.info("/playlist por %s", identity)
        log.info("/playlist: %s", body.url)


@app.get("/search")
async def search(
    q: str = Query(min_length=1, max_length=256),
    limit: int = Query(default=20, ge=1, le=config.MAX_SEARCH_RESULTS),
    identity: str = Depends(enforce_rate_limit),
) -> dict:
    log.info("/search por %s", identity)
    log.info("/search: %s", q)
    try:
        results = await _run(ytdlp_client.search, q, limit)
    except ytdlp_client.EXTRACTION_ERRORS as e:
        raise _extraction_error(e) from e
    return {"results": results}


def _daily_quota_response(e: quota.QuotaExceeded) -> JSONResponse:
    """A diferencia de `enforce_rate_limit` (que también manda 429), este
    cuerpo lleva `reason`/`usedToday`/`dailyLimit` como campos de primer
    nivel — no anidados bajo `detail`, porque HTTPException sólo deja poner
    ahí un string — para que la app pueda mostrar "llegaste a tus 150 de
    hoy" en vez de un error genérico (D-2 del plan de seguridad)."""
    return JSONResponse(
        status_code=status.HTTP_429_TOO_MANY_REQUESTS,
        headers={"Retry-After": str(e.retry_after_seconds)},
        content={
            "detail": f"Llegaste a tu cupo diario de {e.limit} canciones. Volvé mañana.",
            "reason": "daily_song_quota",
            "usedToday": e.used,
            "dailyLimit": e.limit,
        },
    )


async def _record_song_delivered(identity: str) -> None:
    if config.DAILY_SONGS_PER_USER > 0 and _quota_store is not None:
        await quota.record_song(_quota_store, identity, config.DAILY_SONGS_PER_USER)


@app.get("/usage")
async def usage(identity: str = Depends(resolve_identity)) -> dict:
    """Cupo diario de CANCIONES restante para quien pide (no de peticiones —
    ver `rate_limit.py`), lo que `ImportScreen` enseña para que llegar al
    límite no sea una sorpresa (D-2 del plan de seguridad). Sin
    `enforce_rate_limit` a propósito: leer el propio cupo no toca YouTube ni
    gasta ese presupuesto, así que no tiene sentido limitarlo igual."""
    if config.DAILY_SONGS_PER_USER <= 0 or _quota_store is None:
        return {"usedToday": 0, "dailyLimit": 0}
    today = datetime.datetime.now(datetime.timezone.utc).date()
    used = await _quota_store.get_count(identity, today)
    return {"usedToday": used, "dailyLimit": config.DAILY_SONGS_PER_USER}


@app.get("/audio/{video_id}")
async def audio(video_id: str, request: Request, identity: str = Depends(enforce_rate_limit)):
    """Devuelve el M4A original, sin recodificar.

    Bloquea mientras yt-dlp lo baja en el servidor (típico 3-15 s) y luego lo
    sirve. Se eligió esto sobre un modelo job+polling por simplicidad; el
    coste es que la app no puede mostrar progreso por bytes hasta que empieza
    la transferencia. Migrar a jobs sería aditivo si algún día molesta.
    """
    if not _VIDEO_ID_RE.match(video_id):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="id de vídeo inválido")

    if config.DAILY_SONGS_PER_USER > 0 and _quota_store is not None:
        # Antes de gastar presupuesto de extracción: si ya no queda cupo, ni
        # siquiera vale la pena pedirle el vídeo a yt-dlp.
        try:
            await quota.check_quota(_quota_store, identity, config.DAILY_SONGS_PER_USER)
        except quota.QuotaExceeded as e:
            return _daily_quota_response(e)

    log.info("/audio por %s", identity)
    log.info("/audio: %s", video_id)
    try:
        path: Path = await _run(ytdlp_client.fetch_audio, video_id)
    except ytdlp_client.NoAudioTrackError as e:
        # 415 y no 502: es definitivo para este vídeo, el cliente no debe
        # reintentarlo. DownloadProvider distingue ambos casos.
        raise HTTPException(status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, detail=str(e)) from e
    except ytdlp_client.EXTRACTION_ERRORS as e:
        raise _extraction_error(e) from e

    file_size = path.stat().st_size
    headers = {
        "Accept-Ranges": "bytes",
        "Content-Disposition": f'attachment; filename="{video_id}.m4a"',
    }

    range_header = request.headers.get("range")
    if not range_header:
        # Se cuenta acá, no en un `finally`: FileResponse todavía no mandó un
        # solo byte en este punto, pero yt-dlp ya hizo el trabajo real (bajar
        # el vídeo) — que es el presupuesto que el cupo protege. Un corte de
        # red DESPUÉS de esto (mientras Starlette transmite el archivo) queda
        # sin cubrir a propósito: distinguirlo exigiría enganchar el fin real
        # de la transferencia, que StreamingResponse no expone barato, y el
        # cupo es un límite de producto (150/día), no un contador exacto.
        await _record_song_delivered(identity)
        return FileResponse(path, media_type="audio/mp4", headers=headers)

    # Range parcial, para que la app pueda reanudar una transferencia cortada
    # sin volver a pedirle el vídeo a YouTube.
    match = re.match(r"bytes=(\d*)-(\d*)", range_header.strip())
    if not match:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="cabecera Range inválida")
    start_raw, end_raw = match.groups()
    start = int(start_raw) if start_raw else 0
    end = int(end_raw) if end_raw else file_size - 1
    if start >= file_size or start > end:
        return Response(
            status_code=status.HTTP_416_REQUESTED_RANGE_NOT_SATISFIABLE,
            headers={"Content-Range": f"bytes */{file_size}"},
        )
    end = min(end, file_size - 1)
    length = end - start + 1

    def _iter():
        with open(path, "rb") as handle:
            handle.seek(start)
            remaining = length
            while remaining > 0:
                chunk = handle.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
                yield chunk

    # Igual que la rama sin Range: se cuenta acá porque yt-dlp ya hizo el
    # trabajo real, no cuando el stream termina de transmitirse de verdad.
    # El cliente de la app hoy nunca manda Range al pedir /audio (sólo lo
    # soporta el servidor, para reanudar una transferencia cortada más
    # adelante) — si algún día lo hace, un mismo vídeo pedido primero entero
    # y luego reanudado por Range podría contar dos veces; un límite de
    # producto de 150/día no necesita ser un contador exacto para eso.
    await _record_song_delivered(identity)
    return StreamingResponse(
        _iter(),
        status_code=status.HTTP_206_PARTIAL_CONTENT,
        media_type="audio/mp4",
        headers={
            **headers,
            "Content-Range": f"bytes {start}-{end}/{file_size}",
            "Content-Length": str(length),
        },
    )


@app.delete("/cache", dependencies=[Depends(require_admin), Depends(enforce_rate_limit)])
async def clear_cache() -> dict:
    removed = 0
    if config.CACHE_DIR.is_dir():
        for path in config.CACHE_DIR.glob("*.m4a"):
            try:
                path.unlink()
                removed += 1
            except OSError:
                continue
    return {"removed": removed}


if __name__ == "__main__":
    # Permite `python -m app.main` además de `uvicorn app.main:app`, para que
    # run-api.bat sea una sola línea sin recordar la ruta del ASGI app.
    import uvicorn

    uvicorn.run("app.main:app", host=config.HOST, port=config.PORT)
