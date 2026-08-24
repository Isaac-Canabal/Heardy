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


def test_clave_ausente_e_invalida_dan_el_mismo_detail():
    # S5: no darle a quien no tiene ninguna clave una pista de si el problema
    # es "no mandaste nada" o "lo que mandaste está mal".
    with pytest.raises(HTTPException) as sin_clave:
        auth.require_api_key(x_api_key=None)
    with pytest.raises(HTTPException) as clave_mala:
        auth.require_api_key(x_api_key="no-es-una-clave-valida")
    assert sin_clave.value.detail == clave_mala.value.detail


class TestRequireAdmin:
    """require_admin: una clave válida no alcanza, además hace falta que su
    etiqueta esté en config.ADMIN_LABELS."""

    @pytest.fixture(autouse=True)
    def etiquetas_admin(self, monkeypatch):
        monkeypatch.setattr(config, "ADMIN_LABELS", frozenset({"isaac"}))

    def test_etiqueta_admin_pasa(self):
        assert auth.require_admin(identity="isaac") == "isaac"

    def test_clave_valida_pero_sin_ser_admin_da_404(self):
        # 404, no 403: no le confirma a quien no es admin que la ruta existe.
        with pytest.raises(HTTPException) as exc:
            auth.require_admin(identity="ana")
        assert exc.value.status_code == 404

    def test_admin_labels_vacio_rechaza_a_todos(self, monkeypatch):
        monkeypatch.setattr(config, "ADMIN_LABELS", frozenset())
        with pytest.raises(HTTPException) as exc:
            auth.require_admin(identity="isaac")
        assert exc.value.status_code == 404
