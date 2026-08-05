"""Tests de app.main.is_allowed_youtube_url — función pura, sin tocar la red
ni el servidor. Ver ytdlp_client._base_opts (allowed_extractors) para la
otra mitad del arreglo SSRF que este módulo no cubre."""
import pytest
from fastapi import HTTPException

from app.main import _require_allowed_url, is_allowed_youtube_url

_VID = "84YBqfpCGW8"
_LIST = "PLUHWmbNnrtHcOfz3iqN65eoegf9kcEQC6"


def test_watch_url_permitida():
    allowed, _ = is_allowed_youtube_url(f"https://www.youtube.com/watch?v={_VID}")
    assert allowed


def test_youtu_be_permitida():
    allowed, _ = is_allowed_youtube_url(f"https://youtu.be/{_VID}")
    assert allowed


def test_music_youtube_permitida():
    allowed, _ = is_allowed_youtube_url(f"https://music.youtube.com/watch?v={_VID}")
    assert allowed


def test_playlist_por_list_permitida():
    allowed, _ = is_allowed_youtube_url(f"https://www.youtube.com/playlist?list={_LIST}")
    assert allowed


def test_playlist_por_watch_y_list_permitida():
    allowed, _ = is_allowed_youtube_url(
        f"https://www.youtube.com/watch?v={_VID}&list={_LIST}"
    )
    assert allowed


def test_host_case_insensitive():
    allowed, _ = is_allowed_youtube_url(f"https://WWW.YOUTUBE.COM/watch?v={_VID}")
    assert allowed


def test_ssrf_loopback_pot_provider_rechazada():
    allowed, _ = is_allowed_youtube_url("http://127.0.0.1:4416/ping")
    assert not allowed


def test_ssrf_lan_privada_rechazada():
    allowed, _ = is_allowed_youtube_url("http://192.168.1.1/")
    assert not allowed


def test_ssrf_tailscale_cgnat_rechazada():
    allowed, _ = is_allowed_youtube_url("http://100.64.1.1/")
    assert not allowed


def test_host_no_youtube_rechazado():
    allowed, _ = is_allowed_youtube_url("https://vimeo.com/123456")
    assert not allowed


def test_esquema_no_http_rechazado():
    allowed, _ = is_allowed_youtube_url("ftp://youtube.com/")
    assert not allowed


def test_dominio_con_youtube_como_subdominio_ajeno_rechazado():
    # hostname real es "youtube.com.evil.com" — no está en la allowlist.
    allowed, _ = is_allowed_youtube_url("https://youtube.com.evil.com/")
    assert not allowed


def test_youtube_en_query_no_engana_al_parser():
    # hostname real es "evil.com" — el "youtube.com" está en el query string,
    # no en el host. urlparse().hostname no se deja engañar por esto.
    allowed, _ = is_allowed_youtube_url("https://evil.com/?x=youtube.com")
    assert not allowed


def test_motivo_de_rechazo_no_se_filtra_al_cliente():
    # El motivo es para el log, no para la respuesta HTTP — eso lo cubre
    # _require_allowed_url en main.py (probado vía el detail idéntico "URL
    # no válida" en todos los casos, no aquí). Este test solo confirma que
    # is_allowed_youtube_url sigue devolviendo *algún* motivo interno útil.
    allowed, reason = is_allowed_youtube_url("https://vimeo.com/123456")
    assert not allowed
    assert reason


@pytest.mark.parametrize(
    "url",
    [
        "http://127.0.0.1:4416/ping",
        "http://192.168.1.1/",
        "http://100.64.1.1/",
        "https://vimeo.com/123456",
        "ftp://youtube.com/",
        "https://youtube.com.evil.com/",
        "https://evil.com/?x=youtube.com",
    ],
)
def test_require_allowed_url_da_400_con_mensaje_generico_identico(url):
    with pytest.raises(HTTPException) as exc:
        _require_allowed_url(url)
    assert exc.value.status_code == 400
    # Mismo detail para CUALQUIER motivo de rechazo — no debe filtrar si el
    # problema fue el esquema, el host, o un parseo roto (eso sería un
    # oráculo para un atacante sondeando la red interna).
    assert exc.value.detail == "URL no válida"


@pytest.mark.parametrize(
    "url",
    [
        f"https://www.youtube.com/watch?v={_VID}",
        f"https://youtu.be/{_VID}",
        f"https://music.youtube.com/watch?v={_VID}",
        f"https://www.youtube.com/playlist?list={_LIST}",
        f"https://www.youtube.com/watch?v={_VID}&list={_LIST}",
    ],
)
def test_require_allowed_url_deja_pasar_la_bateria_valida(url):
    _require_allowed_url(url)  # no debe lanzar
