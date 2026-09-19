"""/resolve saca sólo metadata, y cae a la extracción completa si eso falla.

Motivo: la extracción completa repite por vídeo el trabajo caro (PO token,
"n challenge" en Node, un cliente de YouTube tras otro) que /audio va a
volver a hacer segundos después. Medido: los mismos campos en 2-3 s en vez
de 17-25 s.
"""
import pytest

from app import ytdlp_client

INFO_OK = {"id": "abc", "title": "Tema", "duration": 200, "webpage_url": "https://www.youtube.com/watch?v=abc"}


def _fake_extract(calls, light_result=None, light_error=None, full_result=INFO_OK):
    def extract(url, opts):
        es_ligero = opts.get("ignore_no_formats_error") is True
        calls.append("ligero" if es_ligero else "completo")
        if es_ligero:
            if light_error is not None:
                raise light_error
            return light_result
        return full_result

    return extract


def test_el_camino_ligero_basta_cuando_trae_titulo_y_duracion(monkeypatch):
    calls = []
    monkeypatch.setattr(ytdlp_client, "_extract", _fake_extract(calls, light_result=INFO_OK))
    monkeypatch.setattr(ytdlp_client, "_thumbnail_exists", lambda _url: True)
    track = ytdlp_client.resolve("https://www.youtube.com/watch?v=abc")
    assert track["title"] == "Tema" and track["durationSeconds"] == 200
    assert calls == ["ligero"]


def test_si_el_ligero_falla_se_repite_completo(monkeypatch):
    calls = []
    monkeypatch.setattr(
        ytdlp_client,
        "_extract",
        _fake_extract(calls, light_error=ytdlp_client.ExtractionError("no hay respuesta embebida")),
    )
    monkeypatch.setattr(ytdlp_client, "_thumbnail_exists", lambda _url: True)
    track = ytdlp_client.resolve("https://www.youtube.com/watch?v=abc")
    assert track["title"] == "Tema"
    assert calls == ["ligero", "completo"]


def test_si_el_ligero_vuelve_sin_duracion_se_repite_completo(monkeypatch):
    calls = []
    monkeypatch.setattr(ytdlp_client, "_extract", _fake_extract(calls, light_result={"id": "abc", "title": "Tema"}))
    monkeypatch.setattr(ytdlp_client, "_thumbnail_exists", lambda _url: True)
    ytdlp_client.resolve("https://www.youtube.com/watch?v=abc")
    assert calls == ["ligero", "completo"]


def test_un_fallo_definitivo_del_completo_es_el_que_manda(monkeypatch):
    def extract(url, opts):
        raise ytdlp_client.PermanentlyUnavailableError("Video unavailable")

    monkeypatch.setattr(ytdlp_client, "_extract", extract)
    with pytest.raises(ytdlp_client.PermanentlyUnavailableError):
        ytdlp_client.resolve("https://www.youtube.com/watch?v=abc")


def test_las_opciones_ligeras_no_piden_pot_ni_player_js():
    opts = ytdlp_client._metadata_only_opts()
    youtube = opts["extractor_args"]["youtube"]
    assert youtube["player_client"] == ["web"]
    assert youtube["fetch_pot"] == ["never"]
    assert youtube["player_skip"] == ["js"]
    assert opts["ignore_no_formats_error"] is True
    # Y el proveedor de PO tokens sigue configurado para cuando haga falta el completo.
    assert any(key.startswith("youtubepot-") for key in opts["extractor_args"])
