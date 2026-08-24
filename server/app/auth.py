"""Autenticación por clave(s) de API.

Soporta tanto una sola clave compartida (servidor personal, HEARDY_API_KEY)
como varias claves con nombre (servidor oficial, HEARDY_API_KEYS) — ambas
conviven en `config.API_KEYS`, ver config.py."""
import hmac

from fastapi import Depends, Header, HTTPException, status

from . import config


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
    # está viendo. El nombre de la cabecera no es un secreto — está en
    # /openapi.json cuando HEARDY_ENABLE_DOCS está activo, y en el propio
    # README — así que unificar el texto es higiene, no el cierre de una vía
    # de ataque nueva.
    if not x_api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="X-Api-Key ausente o inválida",
        )

    label = _match(x_api_key, config.API_KEYS)
    if label is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="X-Api-Key ausente o inválida",
        )
    return label


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
