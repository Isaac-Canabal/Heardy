"""La caché del player preprocesado de yt-dlp, y su rotación.

Es la palanca de memoria más grande del servidor (ver
ytdlp_client.enable_preprocessed_player_cache): sin ella, cada extracción
parsea el player entero en un Node de ~300 MB; con ella, ~60 MB. yt-dlp la
trae apagada porque no rota los archivos — la rotación es nuestra y se prueba
aquí sobre un directorio temporal.
"""
import os
import time

import pytest

from app import ytdlp_client

ejs = pytest.importorskip("yt_dlp.extractor.youtube.jsc._builtin.ejs")


@pytest.fixture
def restore_flag():
    original = ejs.EJSBaseJCP._ENABLE_PREPROCESSED_PLAYER_CACHE
    yield
    ejs.EJSBaseJCP._ENABLE_PREPROCESSED_PLAYER_CACHE = original


def test_activa_la_cache_en_la_clase_de_yt_dlp(restore_flag):
    ejs.EJSBaseJCP._ENABLE_PREPROCESSED_PLAYER_CACHE = False
    assert ytdlp_client.enable_preprocessed_player_cache() is True
    assert ejs.EJSBaseJCP._ENABLE_PREPROCESSED_PLAYER_CACHE is True


def _touch(path, age_seconds):
    path.write_text("{}")
    stamp = time.time() - age_seconds
    os.utime(path, (stamp, stamp))


def test_la_rotacion_deja_los_mas_recientes_y_no_toca_los_scripts(tmp_path):
    folder = tmp_path / "challenge-solver"
    folder.mkdir()
    # Nombre real que produce yt-dlp: la URL del player con "%" -> ",".
    _touch(folder / "player,3Ahttps,3A,2F,2Fyoutube.com,2Fplayer,2Faaaa,2Fbase.js.json", age_seconds=300)
    _touch(folder / "player,3Ahttps,3A,2F,2Fyoutube.com,2Fplayer,2Fbbbb,2Fbase.js.json", age_seconds=200)
    _touch(folder / "player,3Ahttps,3A,2F,2Fyoutube.com,2Fplayer,2Fcccc,2Fbase.js.json", age_seconds=100)
    _touch(folder / "lib.json", age_seconds=1000)
    _touch(folder / "core.json", age_seconds=1000)

    removed = ytdlp_client.prune_preprocessed_players(tmp_path, keep=2)

    assert removed == 1
    remaining = sorted(p.name for p in folder.iterdir())
    assert "player,3Ahttps,3A,2F,2Fyoutube.com,2Fplayer,2Faaaa,2Fbase.js.json" not in remaining
    assert "lib.json" in remaining and "core.json" in remaining
    assert sum(1 for name in remaining if name.startswith("player,3A")) == 2


def test_la_rotacion_sin_carpeta_no_falla(tmp_path):
    assert ytdlp_client.prune_preprocessed_players(tmp_path / "no-existe") == 0
