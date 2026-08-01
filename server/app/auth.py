"""Autenticación por clave compartida."""
import hmac

from fastapi import Header, HTTPException, status

from . import config


def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    """Dependencia de FastAPI: valida la cabecera X-Api-Key.

    La comparación es en tiempo constante (`hmac.compare_digest`) porque una
    comparación normal filtra la clave carácter a carácter ante un atacante
    que pueda medir tiempos — barato de evitar, caro de descubrir después.
    """
    if config.ALLOW_NO_AUTH:
        return

    if not config.API_KEY:
        # No debería llegar aquí: main.py aborta el arranque en este caso.
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="El servidor no tiene HEARDY_API_KEY configurada",
        )

    if not x_api_key or not hmac.compare_digest(x_api_key, config.API_KEY):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="X-Api-Key ausente o inválida",
        )
