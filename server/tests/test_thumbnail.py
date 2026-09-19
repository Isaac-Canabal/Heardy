"""La carátula que /resolve manda a la app: JPEG que exista, nunca WebP.

yt-dlp elige `maxresdefault.webp` como "mejor" miniatura; un .m4a sólo admite
JPEG/PNG como carátula y el escritor de tags de la app descarta el WebP en
silencio — las canciones descargadas quedaban sin carátula.
"""
from app import ytdlp_client

INFO = {
    "thumbnail": "https://i.ytimg.com/vi_webp/abc/maxresdefault.webp",
    "thumbnails": [
        {"url": "https://i.ytimg.com/vi_webp/abc/hqdefault.webp", "preference": -6},
        {"url": "https://i.ytimg.com/vi/abc/sddefault.jpg", "preference": -5},
        {"url": "https://i.ytimg.com/vi/abc/hq720.jpg?sqp=xyz", "preference": -3},
        {"url": "https://i.ytimg.com/vi/abc/maxresdefault.jpg", "preference": -1},
        {"url": "https://i.ytimg.com/vi_webp/abc/maxresdefault.webp", "preference": 0},
    ],
}


def test_candidatas_son_jpeg_de_mejor_a_peor_y_el_webp_se_convierte():
    assert ytdlp_client.jpeg_thumbnail_candidates(INFO) == [
        "https://i.ytimg.com/vi/abc/maxresdefault.jpg",  # el webp, convertido (y sin duplicar con la jpg)
        "https://i.ytimg.com/vi/abc/hq720.jpg?sqp=xyz",
        "https://i.ytimg.com/vi/abc/sddefault.jpg",
        "https://i.ytimg.com/vi/abc/hqdefault.jpg",
    ]


def test_los_fotogramas_numerados_van_detras_aunque_yt_dlp_los_prefiera():
    # Vídeos antiguos: yt-dlp puntúa alto 0.jpg…3.jpg (120×90), inútiles como carátula.
    info = {
        "thumbnails": [
            {"url": "https://i.ytimg.com/vi/old/3.jpg", "preference": 0},
            {"url": "https://i.ytimg.com/vi/old/hqdefault.jpg", "preference": -6},
            {"url": "https://i.ytimg.com/vi/old/mqdefault.jpg", "preference": -7},
        ]
    }
    assert ytdlp_client.jpeg_thumbnail_candidates(info) == [
        "https://i.ytimg.com/vi/old/hqdefault.jpg",
        "https://i.ytimg.com/vi/old/mqdefault.jpg",
        "https://i.ytimg.com/vi/old/3.jpg",
    ]
    # Y si ninguna de las probadas existe, el respaldo es hqdefault, no la última.
    assert ytdlp_client.pick_thumbnail(info, probe=lambda _u: False) == "https://i.ytimg.com/vi/old/hqdefault.jpg"


def test_con_probe_gana_la_primera_que_existe():
    # maxresdefault no existe para este vídeo (yt-dlp la lista igual).
    existentes = {"https://i.ytimg.com/vi/abc/hq720.jpg?sqp=xyz"}
    assert ytdlp_client.pick_thumbnail(INFO, probe=existentes.__contains__) == "https://i.ytimg.com/vi/abc/hq720.jpg?sqp=xyz"


def test_si_ninguna_de_las_probadas_existe_cae_a_hqdefault_sin_probarla():
    assert ytdlp_client.pick_thumbnail(INFO, probe=lambda _url: False) == "https://i.ytimg.com/vi/abc/hqdefault.jpg"


def test_sin_probe_devuelve_la_mejor_candidata_sin_red():
    llamadas = []
    assert ytdlp_client.pick_thumbnail(INFO, probe=None) == "https://i.ytimg.com/vi/abc/maxresdefault.jpg"
    assert llamadas == []


def test_sin_miniaturas_jpeg_se_queda_con_la_de_yt_dlp():
    info = {"thumbnail": "https://example.com/cover", "thumbnails": [{"url": "https://example.com/cover"}]}
    assert ytdlp_client.pick_thumbnail(info, probe=lambda _url: True) == "https://example.com/cover"


def test_to_track_no_prueba_la_red_en_listados(monkeypatch):
    monkeypatch.setattr(ytdlp_client, "_thumbnail_exists", lambda _url: (_ for _ in ()).throw(AssertionError("red")))
    track = ytdlp_client._to_track({"id": "abc", "title": "T", **INFO})
    assert track["thumbnailUrl"] == "https://i.ytimg.com/vi/abc/maxresdefault.jpg"
