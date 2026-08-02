"""Tests de app.auth.require_api_key, llamado directamente (es una función
sync normal; Header(default=None) no necesita un TestClient para probarse)."""
import pytest
from fastapi import HTTPException

from app import auth, config


@pytest.fixture(autouse=True)
def claves_de_prueba(monkeypatch):
    monkeypatch.setattr(config, "ALLOW_NO_AUTH", False)
    monkeypatch.setattr(config, "API_KEYS", {"key-isaac": "isaac", "key-ana": "ana"})


def test_no_auth_bypass(monkeypatch):
    monkeypatch.setattr(config, "ALLOW_NO_AUTH", True)
    assert auth.require_api_key(x_api_key=None) == "no-auth"


def test_clave_ausente_da_401():
    with pytest.raises(HTTPException) as exc:
        auth.require_api_key(x_api_key=None)
    assert exc.value.status_code == 401


def test_clave_incorrecta_da_401():
    with pytest.raises(HTTPException) as exc:
        auth.require_api_key(x_api_key="no-es-una-clave-valida")
    assert exc.value.status_code == 401


def test_clave_valida_devuelve_su_propia_etiqueta():
    assert auth.require_api_key(x_api_key="key-isaac") == "isaac"
    assert auth.require_api_key(x_api_key="key-ana") == "ana"


def test_servidor_sin_ninguna_clave_configurada_da_503(monkeypatch):
    monkeypatch.setattr(config, "API_KEYS", {})
    with pytest.raises(HTTPException) as exc:
        auth.require_api_key(x_api_key="lo-que-sea")
    assert exc.value.status_code == 503
