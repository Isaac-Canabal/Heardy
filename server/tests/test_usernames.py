"""Tests de app.usernames — normalización y validación, funciones puras."""
from app import usernames


def test_normaliza_ancho_completo_y_mayusculas():
    # "ＩＳＡＡＣ" en formas de ancho completo (compatibilidad NFKC) colapsa a "isaac".
    assert usernames.normalize_username("ＩＳＡＡＣ") == "isaac"
    assert usernames.normalize_username("Isaac") == "isaac"


def test_acepta_nombre_valido():
    valid, reason = usernames.validate_username("isaac_2026")
    assert valid
    assert reason == ""


def test_rechaza_cirilico_explicitamente():
    # 'і' cirílica se dibuja idéntico a 'i' latina — justo el caso que el
    # charset ASCII existe para prevenir (ver CLAUDE.md, "Cloud sync").
    valid, reason = usernames.validate_username("іsaac")
    assert not valid
    assert reason


def test_rechaza_emoji():
    valid, _ = usernames.validate_username("isaac🔥")
    assert not valid


def test_rechaza_muy_corto_o_muy_largo():
    assert not usernames.validate_username("ab")[0]
    assert not usernames.validate_username("a" * 21)[0]


def test_rechaza_reservados():
    assert not usernames.validate_username("admin")[0]
    assert not usernames.validate_username("HEARDY")[0]  # normaliza antes de comparar


def test_rechaza_espacios_y_tildes():
    assert not usernames.validate_username("isaac canabal")[0]
    assert not usernames.validate_username("ísaac")[0]
