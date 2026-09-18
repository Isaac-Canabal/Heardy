"""Los clientes de YouTube que consulta yt-dlp salen de la configuración.

Motivo (2026-09-18, log verboso del servidor oficial): con cookies, los
clientes por defecto de yt-dlp daban dos 403 lentos (web_embedded,
tv_downgraded) y un `web` sólo con formatos SABR — ninguna descarga posible.
"""
from app import config, ytdlp_client


def test_los_clientes_configurados_van_a_extractor_args(monkeypatch):
    monkeypatch.setattr(config, "YT_PLAYER_CLIENTS", ["web_music", "mweb", "web"])
    opts = ytdlp_client._base_opts()
    assert opts["extractor_args"]["youtube"] == {"player_client": ["web_music", "mweb", "web"]}
    # Los argumentos del proveedor de PO tokens siguen ahí: se añade, no se sustituye.
    assert any(key.startswith("youtubepot-") for key in opts["extractor_args"])


def test_sin_clientes_configurados_se_deja_elegir_a_yt_dlp(monkeypatch):
    monkeypatch.setattr(config, "YT_PLAYER_CLIENTS", [])
    assert "youtube" not in ytdlp_client._base_opts()["extractor_args"]
