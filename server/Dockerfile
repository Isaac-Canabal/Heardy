# Imagen de un solo CONTENEDOR pensada para una PaaS gratuita (Render: 512 MB,
# ~0,1 vCPU, un solo servicio siempre encendido). Trae dentro las dos mitades
# del proveedor de PO tokens — el plugin de pip y el servidor Node compilado —
# y elige cómo usarlas por memoria, que es el recurso que de verdad falta:
#
# - Por defecto, "script mode": la API invoca `node generate_once.js` sólo
#   cuando caduca el token cacheado (cada ~6 h), y no hay ningún proceso Node
#   residente. Es el modo con el que la imagen funcionó en Render antes de
#   que existiera el sidecar, y volvió a ser el defecto por una razón
#   medida: yt-dlp lanza SU PROPIO Node transitorio para el "n challenge" y,
#   la primera vez tras cada arranque, ese Node parsea el player entero de
#   YouTube y se lleva cientos de MB durante segundos. Con un sidecar
#   residente de ~100-150 MB al lado, el pico no cabía en 512 MB y la
#   plataforma reiniciaba el servicio en mitad de cada descarga.
#
#   El fallo que hizo abandonar el script mode en su momento (`node ...
#   --version` excedía el plazo de 15 s del plugin con 0,1 vCPU) no era del
#   modo sino de sus plazos: ytdlp_client.tune_script_mode_for_slow_cpu los
#   adapta al arrancar.
#
# - Con HEARDY_POT_SIDECAR=1, el entrypoint levanta el servidor Node como
#   sidecar HTTP en loopback: más rápido por token, pero residente. Para
#   instancias con más de 512 MB.
#
# El docker-compose.yml de este repo (servidor propio) levanta el proveedor en
# un contenedor aparte y no usa ninguno de los dos.

# ---- Etapa 1: averiguar qué versión del plugin se va a instalar -------------
# Las dos mitades del proveedor (plugin de pip + servidor Node) DEBEN coincidir
# en versión. Un desajuste es el fallo silencioso más caro de todo el montaje:
# el servicio arranca, /health dice que todo está bien, y las descargas
# devuelven 403. Es la misma razón por la que existe tools/setup_pot.py, y acá
# se replica su lógica: leer la versión realmente instalada y compilar el
# servidor en esa misma etiqueta, en vez de agarrar la rama por defecto.
FROM python:3.12-slim AS potversion
RUN pip install --no-cache-dir bgutil-ytdlp-pot-provider \
    && python -c "import importlib.metadata as m; print(m.version('bgutil-ytdlp-pot-provider'))" \
       > /pot_version.txt

# ---- Etapa 2: compilar el proveedor en esa versión exacta -------------------
FROM node:22-bookworm-slim AS potbuilder
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=potversion /pot_version.txt /pot_version.txt
RUN set -eux; \
    version="$(cat /pot_version.txt)"; \
    echo "Compilando el proveedor de PO tokens en la versión $version"; \
    git clone --single-branch --branch "$version" \
        https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git /opt/bgutil \
    || { \
        echo "[AVISO] No existe la etiqueta $version; se usa la rama por defecto."; \
        echo "        Verificá que plugin y servidor sean compatibles: un"; \
        echo "        desajuste da 403 aunque /health diga que todo está bien."; \
        git clone --depth 1 \
            https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git /opt/bgutil; \
    }; \
    cd /opt/bgutil/server; \
    # `npm ci` exige un package-lock coherente; `npm install` es más tolerante.
    # Se instalan también las devDependencies porque tsc vive ahí.
    { npm ci --no-audit --no-fund || npm install --no-audit --no-fund; }; \
    npx tsc; \
    # El script que invoca el plugin en script mode. Si no está, la imagen es
    # inútil y es mejor fallar acá que descubrirlo con un 403 en producción.
    test -f build/generate_once.js; \
    npm prune --omit=dev --no-audit --no-fund

# ---- Etapa 3: imagen final --------------------------------------------------
FROM python:3.12-slim

# ffmpeg no está en la ruta normal (DD4: nunca se recodifica), pero yt-dlp lo
# usa para remuxear cuando el formato llega en fragmentos DASH separados, que
# es una parte legítima de "entregar el AAC original intacto".
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Node NO es opcional, por dos motivos distintos:
#   1. `ytdlp_client.py` declara `js_runtimes: {deno, node}` para resolver el
#      "n challenge" de YouTube junto con el paquete `yt-dlp-ejs`. Sin runtime
#      de JS, yt-dlp tiene el script y nada con qué ejecutarlo, y el fallo es
#      SILENCIOSO (el servidor corre con quiet=True): /resolve sigue bien y
#      sólo /audio devuelve 403. Fue exactamente la avería del 2026-08-17, que
#      en ejecución nativa no se veía porque el PC ya tenía Node instalado.
#   2. El script mode del proveedor de PO tokens es una app Node.
# Se copia el binario del runtime oficial en vez de instalar el `nodejs` de
# Debian, que en bookworm es la 18 y el proveedor pide >= 20.
COPY --from=node:22-bookworm-slim /usr/local/bin/node /usr/local/bin/node

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Sólo lo compilado + dependencias de producción; el repo entero y npm/git se
# quedan en la etapa de build.
COPY --from=potbuilder /opt/bgutil/server /opt/bgutil-server

COPY app ./app
COPY docker-entrypoint.sh /srv/docker-entrypoint.sh
RUN chmod +x /srv/docker-entrypoint.sh

# Sin privilegios: este servicio habla con internet y ejecuta un extractor
# que cambia cada semana.
RUN useradd --system --create-home --uid 10001 heardy \
    && mkdir -p /data/cache/xdg \
    && chown -R heardy:heardy /data
USER heardy

# Los valores por defecto de config.py están pensados para ejecución nativa
# (caché junto al proyecto, loopback). Dentro del contenedor hay que
# sobreescribirlos: el volumen está en /data y hay que escuchar en todas las
# interfaces para que el mapeo de puertos llegue a algo.
#
# Lo demás es presupuesto de memoria para 512 MB (ver la cabecera):
# - SCRIPT_HOME activa el script mode del proveedor de PO tokens (sin Node
#   residente). La plataforma puede anularlo con HEARDY_POT_SIDECAR=1.
# - MAX_CONCURRENT=1: dos extracciones a la vez son dos Node transitorios (o
#   un Node y un ffmpeg) sumados. Con 0,1 vCPU tampoco había throughput que
#   perder.
# - XDG_CACHE_HOME dentro del volumen: ahí guarda el proveedor su token de
#   integridad entre invocaciones, y así sobrevive a un reinicio si el
#   volumen es persistente en vez de rehacerse desde cero cada vez.
# - MALLOC_ARENA_MAX=2: cada hilo del pool de asyncio.to_thread estrena una
#   arena de glibc y la memoria que yt-dlp libera se queda repartida entre
#   ellas sin volver al sistema. Dos arenas bastan con una extracción a la
#   vez, y es lo que permite que malloc_trim (app/memwatch.py) recorte de
#   verdad el RSS entre descargas.
ENV HEARDY_CACHE_DIR=/data/cache \
    HEARDY_HOST=0.0.0.0 \
    HEARDY_PORT=8080 \
    HEARDY_POT_PROVIDER_SCRIPT_HOME=/opt/bgutil-server \
    HEARDY_MAX_CONCURRENT=1 \
    XDG_CACHE_HOME=/data/cache/xdg \
    MALLOC_ARENA_MAX=2 \
    PYTHONUNBUFFERED=1

EXPOSE 8080

# Sin HEALTHCHECK de Docker a proposito. Las PaaS traen el suyo (Render sondea
# /health por HTTP desde fuera), asi que este solo duplicaba el trabajo - y no
# gratis: lanzaba un interprete de Python entero cada 60 s dentro de un
# contenedor de 512 MB que ya comparte Python, Node y yt-dlp. Para
# docker-compose, curl http://localhost:8080/health cumple la misma funcion.

# El entrypoint levanta el sidecar de PO tokens sólo si se pidió
# (HEARDY_POT_SIDECAR=1) y luego hace `exec` de uvicorn. Resuelve
# `${PORT:-8080}` por su cuenta: las PaaS inyectan el puerto en esa variable y
# dan el servicio por caído si nadie escucha ahí, y el `:-8080` mantiene
# intacto el comportamiento de docker-compose, que no la define.
CMD ["/srv/docker-entrypoint.sh"]
