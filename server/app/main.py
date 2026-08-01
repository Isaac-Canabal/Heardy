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

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("heardy")


@asynccontextmanager
async def lifespan(_: FastAPI):
    if not config.API_KEY and not config.ALLOW_NO_AUTH:
        raise RuntimeError(
            "Falta HEARDY_API_KEY. Generá una y ponela en server/.env, o arrancá con "
            "HEARDY_ALLOW_NO_AUTH=1 si solo escuchás en loopback. "
            "Ver server/README.md."
        )
    config.CACHE_DIR.mkdir(parents=True, exist_ok=True)
    log.info("yt-dlp %s", ytdlp_client.version())
    log.info("proveedor de PO tokens: %s", config.POT_PROVIDER_URL)
    log.info("caché: %s", config.CACHE_DIR)
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
            "authRequired": bool(config.API_KEY) and not config.ALLOW_NO_AUTH,
            "potProvider": {
                "url": config.POT_PROVIDER_URL,
                "reachable": pot_reachable,
                "detail": pot_detail,
            },
            "cache": {"files": cached_files, "maxBytes": config.CACHE_MAX_BYTES},
        }
    )


@app.post("/resolve", dependencies=[Depends(require_api_key)])
async def resolve(body: UrlRequest) -> dict:
    try:
        return await _run(ytdlp_client.resolve, body.url)
    except ytdlp_client.ExtractionError as e:
        raise _extraction_error(e) from e


@app.post("/playlist", dependencies=[Depends(require_api_key)])
async def playlist(body: UrlRequest) -> dict:
    try:
        return await _run(ytdlp_client.resolve_playlist, body.url)
    except ytdlp_client.ExtractionError as e:
        raise _extraction_error(e) from e


@app.get("/search", dependencies=[Depends(require_api_key)])
async def search(
    q: str = Query(min_length=1, max_length=256),
    limit: int = Query(default=20, ge=1, le=config.MAX_SEARCH_RESULTS),
) -> dict:
    try:
        results = await _run(ytdlp_client.search, q, limit)
    except ytdlp_client.ExtractionError as e:
        raise _extraction_error(e) from e
    return {"results": results}


@app.get("/audio/{video_id}", dependencies=[Depends(require_api_key)])
async def audio(video_id: str, request: Request):
    """Devuelve el M4A original, sin recodificar.

    Bloquea mientras yt-dlp lo baja en el servidor (típico 3-15 s) y luego lo
    sirve. Se eligió esto sobre un modelo job+polling por simplicidad; el
    coste es que la app no puede mostrar progreso por bytes hasta que empieza
    la transferencia. Migrar a jobs sería aditivo si algún día molesta.
    """
    if not _VIDEO_ID_RE.match(video_id):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="id de vídeo inválido")

    try:
        path: Path = await _run(ytdlp_client.fetch_audio, video_id)
    except ytdlp_client.NoAudioTrackError as e:
        # 415 y no 502: es definitivo para este vídeo, el cliente no debe
        # reintentarlo. DownloadProvider distingue ambos casos.
        raise HTTPException(status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, detail=str(e)) from e
    except ytdlp_client.ExtractionError as e:
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
