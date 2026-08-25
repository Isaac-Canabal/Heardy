"""Verificación de tokens de ID de Firebase Auth, SIN el SDK completo de
administrador (`firebase-admin`) — sólo lo que hace falta para validar un
token que la app ya obtuvo del lado de Firebase: PyJWT contra las claves
públicas de Google, cacheadas.

No se usa `firebase-admin` a propósito: ese paquete trae un cliente completo
(Firestore, Storage, Cloud Messaging...) que este servidor no necesita para
nada — sólo verificar una firma RS256 y cuatro claims. `PyJWT` + su
`PyJWKClient` hacen exactamente eso, con mucha menos superficie instalada.

Ver DD (Fase 2, servidor, punto 1) en el plan de seguridad: comprobar firma,
`aud`, `iss`, `exp` y `email_verified` — este último es lo que hace exigible
el control de alta (6.1): sin él, cualquiera con un correo inventado podría
registrarse y gastar cuota.
"""
import time

import jwt

from . import config

_JWKS_URL = (
    "https://www.googleapis.com/service_accounts/v1/jwk/"
    "securetoken@system.gserviceaccount.com"
)

# PyJWKClient cachea el JWK set en memoria y sólo vuelve a pedirlo a Google
# cuando expira `lifespan` — una verificación normal no golpea la red en cada
# petición, sólo la primera de cada hora (o tras un cambio de clave del lado
# de Google, si get_signing_key_from_jwt no encuentra el kid en el cache).
_jwk_client = jwt.PyJWKClient(_JWKS_URL, cache_keys=True, lifespan=3600)


class FirebaseTokenError(Exception):
    """Token ausente, mal formado, con firma inválida, expirado, de otro
    proyecto, o con auth_time en el futuro. Mapeado a 401 en auth.py — el
    mismo trato que una X-Api-Key inválida: no hay nada que el usuario pueda
    hacer más que volver a iniciar sesión."""


class EmailNotVerifiedError(FirebaseTokenError):
    """Caso aparte, deliberadamente: el token es genuino y de este proyecto,
    pero la cuenta todavía no verificó su correo. A diferencia de un token
    inválido, esto SÍ lo puede arreglar la propia persona (revisar su
    bandeja), así que auth.py lo mapea a 403, no a 401 — no es "quién sos",
    es "todavía te falta un paso"."""


def verify_id_token(token: str) -> str:
    """Devuelve el `uid` si el token es válido, verificado y de una cuenta
    con el correo confirmado. Lanza `FirebaseTokenError` (o su subclase
    `EmailNotVerifiedError`) en cualquier otro caso — nunca devuelve None ni
    una cadena vacía como "no sé".

    Bloqueante: `PyJWKClient` usa HTTP síncrono para refrescar su cache.
    Llamar siempre dentro de `asyncio.to_thread`, igual que `main.py` ya hace
    con las llamadas a yt-dlp — nunca directo desde una ruta `async def`.
    """
    if not config.FIREBASE_PROJECT_ID:
        raise FirebaseTokenError("HEARDY_FIREBASE_PROJECT_ID no está configurado")

    try:
        signing_key = _jwk_client.get_signing_key_from_jwt(token)
        payload = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=config.FIREBASE_PROJECT_ID,
            issuer=f"https://securetoken.google.com/{config.FIREBASE_PROJECT_ID}",
        )
    except jwt.PyJWTError as e:
        raise FirebaseTokenError(str(e)) from e

    uid = payload.get("sub") or ""
    if not uid:
        raise FirebaseTokenError("token sin 'sub'")

    # PyJWT ya comprueba `exp` (y lo rechazaría más arriba). `auth_time` no lo
    # verifica por defecto — Firebase nunca lo emite en el futuro salvo reloj
    # desincronizado; 60s de margen es tolerar el reloj, no debilitar el chequeo.
    auth_time = payload.get("auth_time")
    if auth_time is not None and auth_time > time.time() + 60:
        raise FirebaseTokenError("auth_time en el futuro")

    if not payload.get("email_verified"):
        raise EmailNotVerifiedError("correo sin verificar")

    return uid
