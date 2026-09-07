# Imagen de un solo CONTENEDOR con dos procesos: la API y el generador de PO
# tokens, que arranca como sidecar HTTP en loopback (ver docker-entrypoint.sh).
#
# El docker-compose.yml de este repo levanta el proveedor en un contenedor
# aparte, que sigue siendo el camino recomendado para un servidor propio. Las
# PaaS gratuitas (Render, etc.) sólo dan UN servicio siempre-encendido, y dos
# servicios que se duermen por separado se rompen entre sí. Pero "un servicio"
# no es "un proceso": el sidecar cabe dentro de este mismo contenedor, y eso
# es lo que hace el entrypoint.
#
# Antes se resolvía con el "script mode" del proveedor, que invoca el
# generador como subproceso por cada token. Costó un fallo en producción: el
# plugin comprueba primero que el script responde (`node ... --version`) con
# un plazo de 15 s propio, y en un plan con ~0,1 vCPU arrancar Node no entra
# ahí. El resultado era un 500 opaco sobre vídeos sanos. Sigue soportado
# (definiendo HEARDY_POT_PROVIDER_SCRIPT_HOME) pero ya no es el camino por
# defecto de esta imagen, y no conviene en una plataforma con poca CPU.

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
    && mkdir -p /data/cache \
    && chown -R heardy:heardy /data
USER heardy

# Los valores por defecto de config.py están pensados para ejecución nativa
# (caché junto al proyecto, loopback). Dentro del contenedor hay que
# sobreescribirlos: el volumen está en /data y hay que escuchar en todas las
# interfaces para que el mapeo de puertos llegue a algo.
#
# HEARDY_POT_PROVIDER_SCRIPT_HOME se deja SIN definir a propósito, y ahora
# tampoco hay que definirla en la plataforma: docker-entrypoint.sh levanta el
# proveedor como sidecar en ESTE mismo contenedor, así que el sidecar HTTP es
# el único camino y el "script mode" queda sólo como alternativa manual. Ver
# el porqué en ese script — resumido: script mode lanza un Node por token y en
# un plan con poca CPU no llega a arrancar dentro del plazo del plugin.
ENV HEARDY_CACHE_DIR=/data/cache \
    HEARDY_HOST=0.0.0.0 \
    HEARDY_PORT=8080 \
    PYTHONUNBUFFERED=1

EXPOSE 8080

# Sin HEALTHCHECK de Docker a proposito. Las PaaS traen el suyo (Render sondea
# /health por HTTP desde fuera), asi que este solo duplicaba el trabajo - y no
# gratis: lanzaba un interprete de Python entero cada 60 s dentro de un
# contenedor de 512 MB que ya comparte Python, Node y yt-dlp. Para
# docker-compose, curl http://localhost:8080/health cumple la misma funcion.

# El entrypoint levanta el proveedor de PO tokens y luego hace `exec` de
# uvicorn. Resuelve `${PORT:-8080}` por su cuenta: las PaaS inyectan el puerto
# en esa variable y dan el servicio por caído si nadie escucha ahí, y el
# `:-8080` mantiene intacto el comportamiento de docker-compose, que no la
# define.
CMD ["/srv/docker-entrypoint.sh"]
