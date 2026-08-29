from app.library_store import compute_artist_key


def test_colapsa_espacios_y_casefold():
    assert compute_artist_key("  Bad   Bunny  ") == "bad bunny"
    assert compute_artist_key("BAD BUNNY") == compute_artist_key("bad bunny")


def test_no_separa_features():
    # A propósito: el cliente tampoco lo hace, y la coherencia con la
    # pantalla local vale más que una agrupación más lista.
    assert compute_artist_key("Bad Bunny feat. Jhayco") == "bad bunny feat. jhayco"
