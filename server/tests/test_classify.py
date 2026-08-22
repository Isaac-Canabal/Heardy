"""Tests de app.ytdlp_client._classify — función pura, sin tocar yt-dlp de
verdad ni la red.

"video unavailable" / "this video is unavailable" se quitaron de
_PERMANENT_MARKERS el 2026-08-22: es el mensaje GENÉRICO que yt-dlp da
cuando el reproductor de YouTube no trae un motivo específico, y eso incluye
fallar en conseguir un PO Token a tiempo bajo el proveedor en modo script
(Render) — no solo un vídeo genuinamente borrado. Medido contra una playlist
real de 68 vídeos: 36 fallaron con exactamente ese mensaje en la primera
racha de peticiones y ninguno de los últimos 24 falló; el mismo vídeo que
"no estaba disponible" en el lote funcionó perfecto probado suelto después.
"""
from app.ytdlp_client import (
    AntiBotBlockError,
    ExtractionError,
    PermanentlyUnavailableError,
    _classify,
)


def test_video_unavailable_ya_no_es_permanente():
    exc = _classify("ERROR: [youtube] xyz: Video unavailable. This video is not available")
    assert isinstance(exc, ExtractionError)
    assert not isinstance(exc, PermanentlyUnavailableError)


def test_this_video_is_unavailable_ya_no_es_permanente():
    exc = _classify("ERROR: [youtube] xyz: This video is unavailable")
    assert isinstance(exc, ExtractionError)
    assert not isinstance(exc, PermanentlyUnavailableError)


def test_video_privado_sigue_siendo_permanente():
    exc = _classify("ERROR: [youtube] xyz: Private video. Sign in if you've been granted access")
    assert isinstance(exc, PermanentlyUnavailableError)


def test_eliminado_por_el_autor_sigue_siendo_permanente():
    exc = _classify("ERROR: [youtube] xyz: Video removed by the uploader")
    assert isinstance(exc, PermanentlyUnavailableError)


def test_cuenta_cerrada_sigue_siendo_permanente():
    exc = _classify(
        "ERROR: [youtube] xyz: This video is no longer available because "
        "the YouTube account associated with this video has been terminated"
    )
    assert isinstance(exc, PermanentlyUnavailableError)


def test_bloqueo_antibot_sigue_siendo_su_propia_categoria():
    exc = _classify("ERROR: [youtube] xyz: Sign in to confirm you're not a bot")
    assert isinstance(exc, AntiBotBlockError)
    assert isinstance(exc, ExtractionError)


def test_error_generico_de_red_es_extraction_error():
    exc = _classify("ERROR: [youtube] xyz: HTTP Error 503: Service Unavailable")
    assert isinstance(exc, ExtractionError)
    assert not isinstance(exc, PermanentlyUnavailableError)
