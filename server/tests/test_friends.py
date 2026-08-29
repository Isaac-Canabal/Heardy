"""Tests de app.friends — sólo la parte de lógica pura (canonical_pair). El
resto (request/accept/remove) vive en SQL sobre `friendships` y sólo se
ejercita contra un Postgres real (mismo criterio que el resto del proyecto
para todo lo que depende de infraestructura externa)."""
import pytest

from app import friends


def test_par_canonico_es_estable_sin_importar_el_orden():
    assert friends.canonical_pair(5, 9) == (5, 9)
    assert friends.canonical_pair(9, 5) == (5, 9)


def test_par_canonico_rechaza_el_mismo_usuario():
    with pytest.raises(ValueError):
        friends.canonical_pair(3, 3)
