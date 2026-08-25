"""Tests de app.auth: require_api_key, require_admin, y resolve_identity —
todas llamadas directamente (son funciones normales, sync o async;
Header(default=None) no necesita un TestClient para probarlas).

resolve_identity NO repite la verificación de firma/claims de Firebase (eso
ya lo cubre test_firebase_auth.py contra tokens reales firmados con una
clave RSA de prueba) — acá se monkeypatchea app.firebase_auth.verify_id_token
para probar sólo el DESPACHO: qué mecanismo se intenta, en qué orden, y cómo
se traduce cada excepción al código HTTP correcto."""
import pytest
from fastapi import HTTPException

from app import auth, config, firebase_auth


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


class TestResolveIdentity:
    """Fase 2: dos mecanismos en paralelo. X-Api-Key ya está cubierto por
    TestRequireApiKey de arriba (resolve_identity delega en require_api_key
    sin cambiarle el comportamiento) — acá se prueba el camino de Firebase y
    la prioridad entre los dos."""

    async def test_sin_ninguna_cabecera_cae_en_require_api_key(self):
        # Mismo resultado que llamar require_api_key directo: 401 genérico.
        with pytest.raises(HTTPException) as exc:
            await auth.resolve_identity(authorization=None, x_api_key=None)
        assert exc.value.status_code == 401

    async def test_x_api_key_sola_funciona_igual_que_siempre(self):
        assert (
            await auth.resolve_identity(authorization=None, x_api_key="key-isaac")
            == "isaac"
        )

    async def test_bearer_valido_devuelve_identidad_con_prefijo_firebase(self, monkeypatch):
        monkeypatch.setattr(firebase_auth, "verify_id_token", lambda token: "uid-abc123")
        identity = await auth.resolve_identity(authorization="Bearer un-token-cualquiera", x_api_key=None)
        assert identity == "firebase:uid-abc123"

    async def test_bearer_tiene_prioridad_sobre_x_api_key_si_ambos_vienen(self, monkeypatch):
        monkeypatch.setattr(firebase_auth, "verify_id_token", lambda token: "uid-abc123")
        identity = await auth.resolve_identity(authorization="Bearer un-token", x_api_key="key-isaac")
        assert identity == "firebase:uid-abc123"

    async def test_bearer_invalido_no_cae_a_x_api_key_como_respaldo(self, monkeypatch):
        # Aunque venga una X-Api-Key válida al mismo tiempo, un Bearer roto
        # es un 401 -- nunca se intenta "a ver si la otra cabecera sirve".
        def _falla(token):
            raise firebase_auth.FirebaseTokenError("token vencido")

        monkeypatch.setattr(firebase_auth, "verify_id_token", _falla)
        with pytest.raises(HTTPException) as exc:
            await auth.resolve_identity(authorization="Bearer vencido", x_api_key="key-isaac")
        assert exc.value.status_code == 401

    async def test_esquema_no_bearer_da_401(self):
        with pytest.raises(HTTPException) as exc:
            await auth.resolve_identity(authorization="Basic dXNlcjpwYXNz", x_api_key=None)
        assert exc.value.status_code == 401

    async def test_bearer_sin_token_da_401(self):
        with pytest.raises(HTTPException) as exc:
            await auth.resolve_identity(authorization="Bearer", x_api_key=None)
        assert exc.value.status_code == 401

    async def test_correo_sin_verificar_da_403_no_401(self, monkeypatch):
        # Distinción real: 403 es "sos vos, pero te falta verificar el
        # correo" -- arreglable por la propia persona, a diferencia de un
        # token genuinamente inválido.
        def _sin_verificar(token):
            raise firebase_auth.EmailNotVerifiedError("correo sin verificar")

        monkeypatch.setattr(firebase_auth, "verify_id_token", _sin_verificar)
        with pytest.raises(HTTPException) as exc:
            await auth.resolve_identity(authorization="Bearer un-token", x_api_key=None)
        assert exc.value.status_code == 403

    async def test_dos_cuentas_de_firebase_dan_identidades_distintas(self, monkeypatch):
        uids = iter(["uid-isaac", "uid-ana"])
        monkeypatch.setattr(firebase_auth, "verify_id_token", lambda token: next(uids))

        primera = await auth.resolve_identity(authorization="Bearer t1", x_api_key=None)
        segunda = await auth.resolve_identity(authorization="Bearer t2", x_api_key=None)

        assert primera != segunda
        assert {primera, segunda} == {"firebase:uid-isaac", "firebase:uid-ana"}

    async def test_identidad_de_firebase_nunca_coincide_con_una_etiqueta_admin(self, monkeypatch):
        # Una cuenta de Firebase nunca es admin por este camino -- ADMIN_LABELS
        # sólo contiene etiquetas de X-Api-Key, y el prefijo "firebase:" hace
        # la colisión imposible incluso si alguien reutiliza el mismo uid
        # como etiqueta de una clave por error.
        monkeypatch.setattr(config, "ADMIN_LABELS", frozenset({"uid-abc123"}))
        monkeypatch.setattr(firebase_auth, "verify_id_token", lambda token: "uid-abc123")
        identity = await auth.resolve_identity(authorization="Bearer un-token", x_api_key=None)
        assert identity not in config.ADMIN_LABELS
