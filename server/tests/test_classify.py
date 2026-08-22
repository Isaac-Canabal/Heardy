"""Tests de app.ytdlp_client._classify — función pura, sin tocar yt-dlp de
verdad ni la red.

"video unavailable" / "this video is unavailable" tienen historia: se
sacaron de _PERMANENT_MARKERS el 2026-08-22 pensando que era un falso
positivo transitorio del proveedor de PO Tokens bajo carga, y se repusieron
el mismo día tras investigar más a fondo. No es transitorio: reintentar el
MISMO vídeo 20 veces seguidas en 8 minutos falló las 20, con los 6 tipos de
cliente que prueba yt-dlp, y confirmado contra la API de YouTube
directamente. Es el bloqueo real de YouTube a nivel de CONTENIDO sobre los
tracks de canales auto-generados "- Topic" (audio oficial con licencia) — 36
de 37 en una playlist real, 0 de 31 "Music Clip" del mismo canal. El arreglo
real vive del lado del cliente (DownloadProvider._tryFallbackSearch): busca
el mismo tema por artista+título y sustituye por un candidato de duración
parecida — casi siempre existe el "Music Clip" oficial. Clasificarlo aquí
como permanente es lo que hace que ese fallback se dispare rápido en vez de
esperar reintentos inútiles contra el mismo id.
"""
from app.ytdlp_client import (
    AntiBotBlockError,
    ExtractionError,
    PermanentlyUnavailableError,
    _classify,
)


def test_video_unavailable_es_permanente():
    exc = _classify("ERROR: [youtube] xyz: Video unavailable. This video is not available")
    assert isinstance(exc, PermanentlyUnavailableError)


def test_this_video_is_unavailable_es_permanente():
    exc = _classify("ERROR: [youtube] xyz: This video is unavailable")
    assert isinstance(exc, PermanentlyUnavailableError)


def test_video_privado_es_permanente():
    exc = _classify("ERROR: [youtube] xyz: Private video. Sign in if you've been granted access")
    assert isinstance(exc, PermanentlyUnavailableError)


def test_eliminado_por_el_autor_es_permanente():
    exc = _classify("ERROR: [youtube] xyz: Video removed by the uploader")
    assert isinstance(exc, PermanentlyUnavailableError)


def test_cuenta_cerrada_es_permanente():
    exc = _classify(
        "ERROR: [youtube] xyz: This video is no longer available because "
        "the YouTube account associated with this video has been terminated"
    )
    assert isinstance(exc, PermanentlyUnavailableError)


def test_bloqueo_antibot_sigue_siendo_su_propia_categoria():
    exc = _classify("ERROR: [youtube] xyz: Sign in to confirm you're not a bot")
    assert isinstance(exc, AntiBotBlockError)
    assert isinstance(exc, ExtractionError)
    assert not isinstance(exc, PermanentlyUnavailableError)


def test_error_generico_de_red_es_extraction_error():
    exc = _classify("ERROR: [youtube] xyz: HTTP Error 503: Service Unavailable")
    assert isinstance(exc, ExtractionError)
    assert not isinstance(exc, PermanentlyUnavailableError)
