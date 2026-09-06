"""Por qué no hubo pista AAC: definitivo o temporal.

La distinción decide si la cola del cliente descarta el trabajo para siempre
(415, no reintentable) o lo reintenta (502). Confundirlas es lo que haría que
una sesión de cookies caducada tirase una tanda entera de canciones sanas con
el veredicto "este vídeo no tiene audio compatible".
"""
from app import ytdlp_client


def _fmt(acodec, ext="webm", vcodec="none"):
    return {"acodec": acodec, "ext": ext, "vcodec": vcodec}


def test_sin_ninguna_pista_de_audio_es_definitivo():
    formats = [_fmt("none", ext="mp4", vcodec="avc1.4d401e")]
    assert ytdlp_client.classify_missing_aac(formats) == "no_audio"


def test_lista_vacia_es_definitivo():
    assert ytdlp_client.classify_missing_aac([]) == "no_audio"


def test_solo_opus_sin_aac_es_lista_recortada():
    # La firma exacta de una IP de datacenter sin sesión válida: YouTube
    # ofrece el audio en webm/opus y esconde el m4a.
    formats = [_fmt("opus"), _fmt("none", ext="mp4", vcodec="avc1.4d401e")]
    assert ytdlp_client.classify_missing_aac(formats) == "degraded"


def test_con_aac_presente_tambien_es_temporal():
    # Si el AAC estaba ahí y aun así falló la selección, desde luego no es
    # "el vídeo no tiene audio" — nunca debe salir como definitivo.
    formats = [_fmt("mp4a.40.2", ext="m4a")]
    assert ytdlp_client.classify_missing_aac(formats) == "degraded"


def test_reconoce_el_aac_por_la_extension_m4a():
    formats = [{"ext": "m4a", "acodec": "aac"}]
    assert ytdlp_client.classify_missing_aac(formats) == "degraded"


def test_acodec_ausente_no_cuenta_como_audio():
    # yt-dlp puede omitir acodec; tratarlo como audio inventaría una pista
    # que no consta.
    assert ytdlp_client.classify_missing_aac([{"ext": "mp4"}]) == "no_audio"
