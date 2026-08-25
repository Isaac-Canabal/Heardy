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

def parse_admin_labels(raw: str) -> frozenset[str]:
    """Convierte `HEARDY_ADMIN_LABELS` ("etiqueta,etiqueta,...") en el
    conjunto de etiquetas con permiso de administrador. Función pura, como
    `parse_api_keys` arriba, para poder probarla sin tocar el entorno."""
    return frozenset(label.strip() for label in raw.split(",") if label.strip())


# Etiquetas (de las de arriba) con permiso de administrador: hoy sólo
# DELETE /cache y GET /health/detail. Vacío por defecto — en un servidor
# personal de una sola clave (etiqueta "default"), un usuario que quiera
# gestionarlo él mismo pone HEARDY_ADMIN_LABELS=default; el servidor oficial
# compartido pone sólo la etiqueta del operador, nunca la de cada beta tester.
ADMIN_LABELS = parse_admin_labels(os.environ.get("HEARDY_ADMIN_LABELS", ""))

# /docs y /openapi.json quedan apagados por defecto: exponen la forma exacta
# de la API (parámetros, que /audio acepta Range, límites declarados) sin
# autenticación, gratis para cualquiera que encuentre la URL del servidor.
# Útil en desarrollo local, no en un despliegue compartido — por eso hace
# falta encenderlo a propósito.
ENABLE_DOCS = os.environ.get("HEARDY_ENABLE_DOCS", "").strip() == "1"

# Id del proyecto de Firebase (Configuración del proyecto → General en la
# consola de Firebase) — NO es secreto, es un identificador público que
# viaja igual dentro de cada token de ID. Se usa para comprobar `aud`/`iss`
# al verificar un token (firebase_auth.py): sin esto, un token de ID
# genuino pero de OTRO proyecto de Firebase pasaría igual la firma. Vacío
# por defecto — un servidor personal que sólo usa X-Api-Key no lo necesita.
FIREBASE_PROJECT_ID = os.environ.get("HEARDY_FIREBASE_PROJECT_ID", "").strip()

# URL del proveedor que genera PO Tokens. Sin él, YouTube devuelve 403 en la
# mayoría de clientes desde 2025 (ver DD1 en CLAUDE.md).
# Por defecto, loopback: es donde escucha el proveedor lanzado con run-pot.bat.
# docker-compose lo cambia a http://bgutil-pot:4416 (nombre del servicio).
POT_PROVIDER_URL = os.environ.get("HEARDY_POT_PROVIDER_URL", "http://127.0.0.1:4416").strip()

# Alternativa al sidecar HTTP de arriba: el "script mode" del proveedor, que
# genera cada token invocando un subproceso Node en vez de hablar con un
# servidor siempre encendido. Vacío = modo HTTP (el de siempre); con valor =
# ruta al directorio `server/` del proveedor ya compilado (el que contiene
# `build/generate_once.js`).
#
# Existe por las PaaS gratuitas, que sólo dan UN servicio: dos servicios que se
# duermen por separado se rompen entre sí, porque la API despierta, llama al
# proveedor dormido y la petición expira antes de que arranque. El costo real,
# documentado por el propio proveedor: es más lento (levanta un proceso Node
# por token) y lleva mal la concurrencia alta — por eso NO es el valor por
# defecto y un servidor propio debería seguir con el sidecar HTTP.
POT_PROVIDER_SCRIPT_HOME = os.environ.get("HEARDY_POT_PROVIDER_SCRIPT_HOME", "").strip()

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

# Fase 3 del plan de seguridad: cupo diario de CANCIONES por identidad (no
# peticiones — ver app/quota.py, "trampa 1" del plan: una canción cuesta
# 2-3 peticiones según de dónde salga, así que RATE_LIMIT_PER_KEY/DAILY_QUOTA
# de arriba no pueden hacer las veces de esto). 0 desactiva, igual que el
# resto de los límites — un servidor personal no lo necesita.
DAILY_SONGS_PER_USER = _int_env("HEARDY_DAILY_SONGS_PER_USER", 0)

# Cadena de conexión a Postgres (Neon en el servidor oficial). Sólo hace
# falta si DAILY_SONGS_PER_USER > 0: un cupo diario necesita almacenamiento
# persistente para significar algo (hallazgo S3 del plan de seguridad — en
# memoria, Render lo resetea solo al dormirse o redesplegar). Vacía por
# defecto; main.py aborta el arranque si el cupo está activo sin esto.
DATABASE_URL = os.environ.get("HEARDY_DATABASE_URL", "").strip()
