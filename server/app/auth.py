"""Autenticación: dos mecanismos que conviven, nunca uno reemplaza al otro.

- `X-Api-Key` — una sola clave compartida (servidor personal, HEARDY_API_KEY)
  o varias claves con nombre (servidor oficial, HEARDY_API_KEYS), ambas en
  `config.API_KEYS` (ver config.py). El mecanismo original, sigue intacto.
- `Authorization: Bearer <token de Firebase>` — el camino del servidor
  oficial desde la Fase 2 del plan de seguridad: cada usuario real tiene su
  propia cuenta, en vez de que todo el APK comparta una clave.

`resolve_identity` es el punto de entrada que decide cuál de los dos se usó y
devuelve una identidad — una cadena — en cualquiera de los dos casos. Todo lo
que vive aguas abajo (rate limiting, logs) trabaja con esa cadena sin saber ni
importarle su origen; sólo `require_admin` sigue atado a `require_api_key`
específicamente, a propósito (ver su docstring)."""
import asyncio
import hmac

from fastapi import Depends, Header, HTTPException, status

from . import config, firebase_auth


def _match(candidate: str, keys: dict[str, str]) -> str | None:
    """Etiqueta de la clave que coincide, o None. Compara contra TODAS las
    claves configuradas (no corta en la primera) para que el tiempo de
    respuesta no filtre cuál de ellas está más cerca de ser correcta."""
    label = None
    for key, key_label in keys.items():
        if hmac.compare_digest(candidate, key):
            label = key_label
    return label


def require_api_key(x_api_key: str | None = Header(default=None)) -> str:
    """Dependencia de FastAPI: valida la cabecera X-Api-Key y devuelve la
    identidad (etiqueta) de la clave usada — "no-auth" si la autenticación
    está desactivada. El valor de retorno alimenta el rate limiting por
    clave (`rate_limit.py`) y los logs, pero el propio chequeo de validez no
    cambia de comportamiento frente a la versión de una sola clave.

    La comparación es en tiempo constante (`hmac.compare_digest`) porque una
    comparación normal filtra la clave carácter a carácter ante un atacante
    que pueda medir tiempos — barato de evitar, caro de descubrir después.
    """
    if config.ALLOW_NO_AUTH:
        return "no-auth"

    if not config.API_KEYS:
        # No debería llegar aquí: main.py aborta el arranque en este caso.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="El servidor no tiene HEARDY_API_KEY/HEARDY_API_KEYS configurada",
        )

    # Mismo detalle para "ausente" e "inválida" a propósito: el código (401)
    # ya es idéntico en los dos casos, que es lo que importa para no darle a
    # quien no tiene ninguna clave una pista sobre cuál de las dos situaciones
    # está viendo. Ninguno de los dos nombres de cabecera es secreto — están
    # en /openapi.json cuando HEARDY_ENABLE_DOCS está activo, y en el propio
    # README — así que un texto genérico es higiene, no el cierre de una vía
    # de ataque nueva.
    if not x_api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Autenticación ausente o inválida",
        )

    label = _match(x_api_key, config.API_KEYS)
    if label is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Autenticación ausente o inválida",
        )
    return label


def _bearer_token(authorization: str) -> str:
    """Extrae el token de `Authorization: Bearer <token>`. Cualquier otra
    forma (otro esquema, sin token) es un 401 — mismo texto genérico que
    `require_api_key`, por la misma razón."""
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Autenticación ausente o inválida",
        )
    return token


async def resolve_identity(
    authorization: str | None = Header(default=None),
    x_api_key: str | None = Header(default=None),
) -> str:
    """La identidad de la petición, por cualquiera de los dos mecanismos.
    Firebase se intenta primero cuando la cabecera `Authorization` está
    presente — es inequívoca, así que si vino es la que se pidió usar; nunca
    se cae a `X-Api-Key` como respaldo silencioso si el Bearer resulta
    inválido, eso ocultaría un token vencido detrás de un 401 sin pista de
    cuál de los dos falló.

    Verificar el token es bloqueante (ver firebase_auth.verify_id_token), así
    que corre en un hilo aparte — mismo patrón que `main.py` usa para no
    congelar el bucle de eventos con las llamadas a yt-dlp.

    La identidad que devuelve para Firebase lleva el prefijo `firebase:` —
    nunca puede confundirse con una etiqueta de X-Api-Key (esas las define el
    operador a mano) ni, más importante, con una etiqueta de
    `config.ADMIN_LABELS`: una cuenta de Firebase nunca es admin por este
    camino, sólo por tener también su propia X-Api-Key (ver require_admin)."""
    if authorization:
        token = _bearer_token(authorization)
        try:
            uid = await asyncio.to_thread(firebase_auth.verify_id_token, token)
        except firebase_auth.EmailNotVerifiedError as e:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Verificá tu correo antes de usar la app",
            ) from e
        except firebase_auth.FirebaseTokenError as e:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Autenticación ausente o inválida",
            ) from e
        return f"firebase:{uid}"

    return require_api_key(x_api_key=x_api_key)


def require_account(identity: str = Depends(resolve_identity)) -> str:
    """Dependencia de FastAPI para toda ruta de cuentas/biblioteca/amigos:
    exige que la identidad venga de Firebase, nunca de una X-Api-Key. Una
    etiqueta de X-Api-Key la define el operador y puede estar compartida por
    varias personas (o por nadie en particular) — no es una cuenta.

    403 y no 404: estas rutas no son secretas (la propia app las llama), así
    que el cliente necesita distinguir "te falta cuenta" de "esto no existe",
    al contrario que require_admin."""
    if not identity.startswith("firebase:"):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Esta función necesita una cuenta",
        )
    return identity


def require_admin(identity: str = Depends(require_api_key)) -> str:
    """Dependencia de FastAPI: además de una clave válida, exige que su
    etiqueta esté en `config.ADMIN_LABELS`. Depende de `require_api_key` (no
    lo reimplementa) para que ambas dependencias en la misma petición resuelvan
    la misma identidad una sola vez — FastAPI cachea por dependencia dentro de
    una petición.

    Usa 404, no 403: un 403 le confirma a quien no es admin que la ruta existe
    y que sólo le falta permiso, invitándolo a probar con otra clave. Un 404
    no distingue "no tenés permiso" de "esto no existe" — la misma razón por
    la que `require_api_key` no distingue clave ausente de inválida."""
    if identity not in config.ADMIN_LABELS:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No encontrado")
    return identity
