"""Tests de app.firebase_auth.verify_id_token — firmando tokens de prueba con
una clave RSA propia, generada acá mismo. Nunca contra Google: se
monkeypatchea `_jwk_client.get_signing_key_from_jwt` para que devuelva la
clave pública de prueba sin ninguna llamada de red, así que estos tests
corren offline y rápido, igual que el resto de la suite."""
import time
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from app import config, firebase_auth

_PROJECT_ID = "heardy-test"
_ISSUER = f"https://securetoken.google.com/{_PROJECT_ID}"


@pytest.fixture(scope="module")
def keypair():
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return private_key, private_key.public_key()


@pytest.fixture(autouse=True)
def firebase_project(monkeypatch):
    monkeypatch.setattr(config, "FIREBASE_PROJECT_ID", _PROJECT_ID)


@pytest.fixture(autouse=True)
def fake_jwk_client(monkeypatch, keypair):
    _, public_key = keypair
    monkeypatch.setattr(
        firebase_auth._jwk_client,
        "get_signing_key_from_jwt",
        lambda token: SimpleNamespace(key=public_key),
    )


def _make_token(keypair, **overrides):
    private_key, _ = keypair
    now = int(time.time())
    payload = {
        "sub": "usuario-123",
        "aud": _PROJECT_ID,
        "iss": _ISSUER,
        "iat": now,
        "exp": now + 3600,
        "auth_time": now,
        "email": "isaac@example.com",
        "email_verified": True,
    }
    payload.update(overrides)
    return jwt.encode(payload, private_key, algorithm="RS256")


def test_token_valido_devuelve_el_uid(keypair):
    token = _make_token(keypair)
    assert firebase_auth.verify_id_token(token) == "usuario-123"


def test_sin_firebase_project_id_configurado(keypair, monkeypatch):
    monkeypatch.setattr(config, "FIREBASE_PROJECT_ID", "")
    token = _make_token(keypair)
    with pytest.raises(firebase_auth.FirebaseTokenError):
        firebase_auth.verify_id_token(token)


def test_audience_de_otro_proyecto_se_rechaza(keypair):
    token = _make_token(keypair, aud="otro-proyecto-de-firebase")
    with pytest.raises(firebase_auth.FirebaseTokenError):
        firebase_auth.verify_id_token(token)


def test_issuer_de_otro_proyecto_se_rechaza(keypair):
    token = _make_token(keypair, iss="https://securetoken.google.com/otro-proyecto")
    with pytest.raises(firebase_auth.FirebaseTokenError):
        firebase_auth.verify_id_token(token)


def test_token_expirado_se_rechaza(keypair):
    now = int(time.time())
    token = _make_token(keypair, iat=now - 7200, exp=now - 3600)
    with pytest.raises(firebase_auth.FirebaseTokenError):
        firebase_auth.verify_id_token(token)


def test_firma_con_otra_clave_se_rechaza(keypair):
    otra_clave_privada = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    now = int(time.time())
    token = jwt.encode(
        {
            "sub": "usuario-123",
            "aud": _PROJECT_ID,
            "iss": _ISSUER,
            "iat": now,
            "exp": now + 3600,
            "email_verified": True,
        },
        otra_clave_privada,
        algorithm="RS256",
    )
    with pytest.raises(firebase_auth.FirebaseTokenError):
        firebase_auth.verify_id_token(token)


def test_sin_sub_se_rechaza(keypair):
    token = _make_token(keypair, sub="")
    with pytest.raises(firebase_auth.FirebaseTokenError):
        firebase_auth.verify_id_token(token)


def test_auth_time_en_el_futuro_se_rechaza(keypair):
    token = _make_token(keypair, auth_time=int(time.time()) + 3600)
    with pytest.raises(firebase_auth.FirebaseTokenError):
        firebase_auth.verify_id_token(token)


def test_correo_sin_verificar_da_email_not_verified_no_firebase_token_error_generico(keypair):
    # Distinción real, no cosmética: auth.py mapea esto a 403 (arreglable por
    # el usuario), el resto de fallos a 401 (token genuinamente inválido).
    token = _make_token(keypair, email_verified=False)
    with pytest.raises(firebase_auth.EmailNotVerifiedError):
        firebase_auth.verify_id_token(token)


def test_email_not_verified_es_tambien_un_firebase_token_error():
    # Quien sólo atrapa la clase base (p. ej. un except genérico) sigue
    # cubierto — EmailNotVerifiedError es una subclase, no un tipo aparte.
    assert issubclass(firebase_auth.EmailNotVerifiedError, firebase_auth.FirebaseTokenError)
