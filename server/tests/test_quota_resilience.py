"""La contabilidad del cupo no puede tumbar una descarga que ya funcionó.

`/audio` apunta la canción DESPUÉS de que yt-dlp la haya bajado: en ese punto
el trabajo caro está hecho y los bytes están listos. Si la base de datos elige
ese instante para no responder —con Neon en plan gratuito pasa, se suspende
por inactividad y mata las conexiones abiertas del pool— la excepción subía
sin traducir y FastAPI devolvía un 500. La descarga había funcionado y la
petición moría haciendo la contabilidad.

El cupo es un límite de producto (150/día), no un invariante de corrección:
perder una cuenta vale infinitamente menos que perder la descarga.
"""
import datetime

import pytest

from app import config, main


class _BrokenQuotaStore:
    """Lo que parece una conexión de asyncpg muerta tras una suspensión."""

    async def get_count(self, identity: str, day: datetime.date) -> int:
        raise ConnectionError("connection was closed in the middle of operation")

    async def increment(self, identity: str, day: datetime.date) -> int:
        raise ConnectionError("connection was closed in the middle of operation")


@pytest.fixture
def cupo_roto(monkeypatch):
    monkeypatch.setattr(main, "_quota_store", _BrokenQuotaStore())
    monkeypatch.setattr(config, "DAILY_SONGS_PER_USER", 150)


async def test_apuntar_la_cancion_no_lanza_si_la_base_no_responde(cupo_roto):
    # No se comprueba un valor de retorno: lo que se comprueba es que NO
    # lanza. Antes de esto, esta misma llamada era un 500 sobre una descarga
    # que ya estaba lista para servirse.
    await main._record_song_delivered("firebase:alguien")


async def test_sin_cupo_configurado_ni_siquiera_toca_la_base(monkeypatch):
    monkeypatch.setattr(main, "_quota_store", _BrokenQuotaStore())
    monkeypatch.setattr(config, "DAILY_SONGS_PER_USER", 0)
    await main._record_song_delivered("firebase:alguien")


async def test_sin_store_no_hace_nada(monkeypatch):
    monkeypatch.setattr(main, "_quota_store", None)
    monkeypatch.setattr(config, "DAILY_SONGS_PER_USER", 150)
    await main._record_song_delivered("firebase:alguien")
