"""Autenticación por clave(s) de API.

Soporta tanto una sola clave compartida (servidor personal, HEARDY_API_KEY)
como varias claves con nombre (servidor oficial, HEARDY_API_KEYS) — ambas
conviven en `config.API_KEYS`, ver config.py."""
import hmac

from fastapi import Header, HTTPException, status

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

    if not x_api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="X-Api-Key ausente",
        )

    label = _match(x_api_key, config.API_KEYS)
    if label is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="X-Api-Key inválida",
        )
    return label
