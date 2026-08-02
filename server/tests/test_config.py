"""Tests de app.config.parse_api_keys — función pura, sin tocar el entorno."""
from app.config import parse_api_keys


def test_sin_claves_de_ningun_tipo():
    assert parse_api_keys("", "") == {}


def test_solo_clave_legacy_queda_como_default():
    assert parse_api_keys("", "abc123") == {"abc123": "default"}


def test_varias_claves_con_etiqueta():
    keys = parse_api_keys("isaac:key1,ana:key2", "")
    assert keys == {"key1": "isaac", "key2": "ana"}


def test_clave_sin_etiqueta_usa_la_clave_como_etiqueta():
    keys = parse_api_keys("key1,key2", "")
    assert keys == {"key1": "key1", "key2": "key2"}


def test_clave_legacy_se_fusiona_si_no_esta_ya_presente():
    keys = parse_api_keys("isaac:key1", "legacykey")
    assert keys == {"key1": "isaac", "legacykey": "default"}


def test_clave_legacy_no_se_duplica_si_ya_esta_en_las_nuevas():
    # Alguien definió HEARDY_API_KEY y también HEARDY_API_KEYS con esa misma
    # clave bajo otra etiqueta: gana la etiqueta explícita, no "default".
    keys = parse_api_keys("isaac:samekey", "samekey")
    assert keys == {"samekey": "isaac"}


def test_entradas_vacias_se_ignoran():
    keys = parse_api_keys("isaac:key1,, ,ana:key2,", "")
    assert keys == {"key1": "isaac", "key2": "ana"}


def test_espacios_alrededor_se_recortan():
    keys = parse_api_keys(" isaac : key1 , ana:key2 ", "")
    assert keys == {"key1": "isaac", "key2": "ana"}
