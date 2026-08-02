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
# pruebas en loopback). Se mantiene tal cual para no romper ningún .env de
# servidor personal ya existente: sigue siendo la única variable que hace
# falta rellenar para el caso de un solo usuario.
API_KEY = os.environ.get("HEARDY_API_KEY", "").strip()
ALLOW_NO_AUTH = os.environ.get("HEARDY_ALLOW_NO_AUTH", "").strip() == "1"


def parse_api_keys(raw: str, legacy_key: str) -> dict[str, str]:
    """Convierte `HEARDY_API_KEYS` ("etiqueta:clave,etiqueta:clave,...") en
    un diccionario clave -> etiqueta. Función pura (no lee el entorno) para
    poder probarla sin monkeypatchear variables globales.

    Formato de cada entrada: `etiqueta:clave`, o solo `clave` (la etiqueta
    pasa a ser la propia clave). Entradas vacías se ignoran.

    `legacy_key` (el valor de HEARDY_API_KEY) se añade siempre bajo la
    etiqueta "default" si no está ya presente — así un servidor personal que
    solo definió HEARDY_API_KEY (el caso de siempre) sigue funcionando
    exactamente igual aunque nunca toque HEARDY_API_KEYS.
    """
    keys: dict[str, str] = {}
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry:
            continue
        label, sep, key = entry.partition(":")
        if sep:
            label, key = label.strip(), key.strip()
        else:
            label, key = entry, entry
        if key:
            keys[key] = label or key
    if legacy_key and legacy_key not in keys:
        keys[legacy_key] = "default"
    return keys


# Varias claves con nombre, para el servidor oficial compartido por un grupo
# cerrado de usuarios: cada persona tiene la suya, así se puede revocar el
# acceso de una sola sin rotar la de las demás, y los logs/el rate limiting
# (ver más abajo) distinguen quién generó qué tráfico. Un servidor personal
# no necesita definir esto — HEARDY_API_KEY solo ya alcanza (ver arriba).
API_KEYS = parse_api_keys(os.environ.get("HEARDY_API_KEYS", ""), API_KEY)

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

# Rate limiting: 0 desactiva. Pensado para el servidor oficial compartido,
# donde varias personas gastan el mismo presupuesto de IP frente a YouTube —
# un servidor personal de un solo usuario no lo necesita, y por eso viene
# desactivado por defecto (comportamiento idéntico al de antes de que esto
# existiera). Ver docs/arquitectura_servidor_hibrido.md, sección 5.
RATE_LIMIT_PER_KEY = _int_env("HEARDY_RATE_LIMIT_PER_KEY", 0)
RATE_LIMIT_WINDOW_SECONDS = _int_env("HEARDY_RATE_LIMIT_WINDOW_SECONDS", 3600)
DAILY_QUOTA = _int_env("HEARDY_DAILY_QUOTA", 0)
