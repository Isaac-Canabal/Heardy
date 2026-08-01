"""Caché LRU en disco de audio ya extraído.

Existe para proteger el recurso escaso, que no es el disco sino el
presupuesto de peticiones por IP hacia YouTube: si la app pierde la conexión
a mitad de una descarga y reintenta, el reintento debe salir del disco.
"""
import threading
import time
from pathlib import Path

from . import config

_lock = threading.Lock()


def path_for(video_id: str) -> Path:
    # El id de YouTube es [A-Za-z0-9_-]{11}, pero esto también sirve ids de
    # otras fuentes: se sanea igualmente para que nunca escape del directorio.
    safe = "".join(c for c in video_id if c.isalnum() or c in "-_")
    return config.CACHE_DIR / f"{safe}.m4a"


def get(video_id: str) -> Path | None:
    path = path_for(video_id)
    if path.is_file() and path.stat().st_size > 0:
        # Marca de uso para el LRU.
        now = time.time()
        try:
            import os

            os.utime(path, (now, path.stat().st_mtime))
        except OSError:
            pass
        return path
    return None


def evict_if_needed() -> None:
    """Borra las entradas menos usadas hasta caber en el presupuesto."""
    with _lock:
        if not config.CACHE_DIR.is_dir():
            return
        entries = []
        total = 0
        for path in config.CACHE_DIR.glob("*.m4a"):
            try:
                stat = path.stat()
            except OSError:
                continue
            entries.append((stat.st_atime, stat.st_size, path))
            total += stat.st_size

        if total <= config.CACHE_MAX_BYTES:
            return

        entries.sort(key=lambda e: e[0])  # el menos usado primero
        for _atime, size, path in entries:
            if total <= config.CACHE_MAX_BYTES:
                break
            try:
                path.unlink()
                total -= size
            except OSError:
                continue
