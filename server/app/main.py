"""API HTTP que Heardy consume para importar audio a la biblioteca local.

Ver ../README.md para despliegue y CLAUDE.md (DD1) para por qué existe este
servicio en vez de un extractor embebido en la app.
"""
import asyncio
import logging
import re
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from fastapi import Depends, FastAPI, HTTPException, Query, Request, status
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from pydantic import BaseModel, Field

from . import config, ytdlp_client
from .auth import require_api_key
from .rate_limit import enforce_rate_limit

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("heardy")


@asynccontextmanager
async def lifespan(_: FastAPI):
    if not config.API_KEYS and not config.ALLOW_NO_AUTH:
        raise RuntimeError(
            "Falta HEARDY_API_KEY o HEARDY_API_KEYS. Generá una clave y ponela en "
            "server/.env, o arrancá con HEARDY_ALLOW_NO_AUTH=1 si solo escuchás en "
            "loopback. Ver server/README.md."
        )
    config.CACHE_DIR.mkdir(parents=True, exist_ok=True)
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
    yield


app = FastAPI(title="Heardy download API", docs_url="/docs", redoc_url=None, lifespan=lifespan)

# Limita las extracciones simultáneas. yt-dlp es bloqueante, así que además
# se ejecuta siempre en un hilo (`asyncio.to_thread`) para no congelar el
# bucle de eventos.
_extraction_semaphore = asyncio.Semaphore(config.MAX_CONCURRENT_EXTRACTIONS)

_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{5,32}$")


class UrlRequest(BaseModel):
    url: str = Field(min_length=5, max_length=2048)


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


@app.get("/health")
async def health() -> JSONResponse:
    """Diagnóstico. Sin autenticación a propósito: la app necesita poder
    distinguir 'servidor apagado' de 'clave incorrecta' antes de tener clave."""
    pot_reachable = False
    pot_detail = "no comprobado"
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            response = await client.get(f"{config.POT_PROVIDER_URL}/ping")
            pot_reachable = response.status_code < 500
            pot_detail = f"HTTP {response.status_code}"
    except Exception as e:  # noqa: BLE001 — es un diagnóstico, cualquier fallo es informativo
        pot_detail = f"inalcanzable: {type(e).__name__}"

    cached_files = len(list(config.CACHE_DIR.glob("*.m4a"))) if config.CACHE_DIR.is_dir() else 0

    return JSONResponse(
        {
            "status": "ok",
            "ytdlpVersion": ytdlp_client.version(),
            "authRequired": bool(config.API_KEYS) and not config.ALLOW_NO_AUTH,
            "potProvider": {
                "url": config.POT_PROVIDER_URL,
                "reachable": pot_reachable,
                "detail": pot_detail,
            },
            "cache": {"files": cached_files, "maxBytes": config.CACHE_MAX_BYTES},
            # Puramente informativo — la app no necesita leer esto para
            # funcionar, es diagnóstico para quien administra el servidor.
            "rateLimiting": {
                "perKeyLimit": config.RATE_LIMIT_PER_KEY,
                "perKeyWindowSeconds": config.RATE_LIMIT_WINDOW_SECONDS,
                "dailyQuota": config.DAILY_QUOTA,
            },
        }
    )


@app.post("/resolve")
async def resolve(body: UrlRequest, identity: str = Depends(enforce_rate_limit)) -> dict:
    try:
        return await _run(ytdlp_client.resolve, body.url)
    except ytdlp_client.EXTRACTION_ERRORS as e:
        raise _extraction_error(e) from e
    finally:
        log.info("/resolve por %s: %s", identity, body.url)


@app.post("/playlist")
async def playlist(body: UrlRequest, identity: str = Depends(enforce_rate_limit)) -> dict:
    try:
        return await _run(ytdlp_client.resolve_playlist, body.url)
    except ytdlp_client.EXTRACTION_ERRORS as e:
        raise _extraction_error(e) from e
    finally:
        log.info("/playlist por %s: %s", identity, body.url)


@app.get("/search")
async def search(
    q: str = Query(min_length=1, max_length=256),
    limit: int = Query(default=20, ge=1, le=config.MAX_SEARCH_RESULTS),
    identity: str = Depends(enforce_rate_limit),
) -> dict:
    log.info("/search por %s: %s", identity, q)
    try:
        results = await _run(ytdlp_client.search, q, limit)
    except ytdlp_client.EXTRACTION_ERRORS as e:
        raise _extraction_error(e) from e
    return {"results": results}


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

    log.info("/audio por %s: %s", identity, video_id)
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


@app.delete("/cache", dependencies=[Depends(require_api_key)])
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
