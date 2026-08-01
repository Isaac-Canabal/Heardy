"""Configuración por entorno. Ver .env.example.

Los valores por defecto están pensados para ejecución **nativa** (python
directamente en la máquina de desarrollo). Docker los sobreescribe con
variables de entorno en docker-compose.yml, así que ninguno de los dos
caminos necesita saber del otro.
"""
import os
from pathlib import Path

from dotenv import load_dotenv

# Raíz del proyecto del servidor (server/), independientemente de desde qué
# directorio se lance el proceso.
SERVER_ROOT = Path(__file__).resolve().parent.parent

# Carga server/.env si existe. Docker usa `env_file` y llega aquí con las
# variables ya puestas; load_dotenv no pisa lo que ya está en el entorno, así
# que ambos caminos conviven sin condicionales.
load_dotenv(SERVER_ROOT / ".env")


def _int_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


# Clave compartida que la app manda en X-Api-Key. Sin ella el servicio se
# niega a arrancar salvo que se ponga HEARDY_ALLOW_NO_AUTH=1 (solo para
# pruebas en loopback).
API_KEY = os.environ.get("HEARDY_API_KEY", "").strip()
ALLOW_NO_AUTH = os.environ.get("HEARDY_ALLOW_NO_AUTH", "").strip() == "1"

# URL del proveedor que genera PO Tokens. Sin él, YouTube devuelve 403 en la
# mayoría de clientes desde 2025 (ver DD1 en CLAUDE.md).
# Por defecto, loopback: es donde escucha el proveedor lanzado con run-pot.bat.
# docker-compose lo cambia a http://bgutil-pot:4416 (nombre del servicio).
POT_PROVIDER_URL = os.environ.get("HEARDY_POT_PROVIDER_URL", "http://127.0.0.1:4416").strip()

# Caché LRU en disco: un reintento tras un corte de red no debe volver a
# golpear a YouTube. El presupuesto de IP es el recurso escaso, no el disco.
CACHE_DIR = Path(os.environ.get("HEARDY_CACHE_DIR") or (SERVER_ROOT / ".cache"))
CACHE_MAX_BYTES = _int_env("HEARDY_CACHE_MAX_MB", 2048) * 1024 * 1024

# Extracciones simultáneas. Deliberadamente bajo: el muro de YouTube es un
# presupuesto acumulado por IP, y la concurrencia lo gasta más rápido sin dar
# throughput real (medido en docs/investigacion_muro_antibot.md).
MAX_CONCURRENT_EXTRACTIONS = _int_env("HEARDY_MAX_CONCURRENT", 2)

# Cota de seguridad para no expandir una playlist de 5.000 vídeos por error.
MAX_PLAYLIST_ENTRIES = _int_env("HEARDY_MAX_PLAYLIST_ENTRIES", 500)
MAX_SEARCH_RESULTS = _int_env("HEARDY_MAX_SEARCH_RESULTS", 50)

# Dirección y puerto donde escucha la API.
# 127.0.0.1 por defecto: para probar desde el móvil hay que ponerlo a 0.0.0.0
# a conciencia (o usar Tailscale), no por accidente.
HOST = os.environ.get("HEARDY_HOST", "127.0.0.1").strip()
PORT = _int_env("HEARDY_PORT", 8080)

# Cookies opcionales (formato Netscape). Suben mucho la tasa de éxito en
# vídeos con restricción de edad, pero atan las descargas a una cuenta real:
# es una decisión del usuario, no un valor por defecto.
COOKIES_FILE = os.environ.get("HEARDY_COOKIES_FILE", "").strip()
