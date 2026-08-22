FROM python:3.12-slim

# ffmpeg no está en la ruta normal (DD4: nunca se recodifica), pero yt-dlp lo
# usa para remuxear cuando el formato llega en fragmentos DASH separados, que
# es una parte legítima de "entregar el AAC original intacto".
#
# nodejs NO es opcional: `ytdlp_client.py` declara `js_runtimes: {deno, node}`
# para resolver el "n challenge" de YouTube junto con el paquete `yt-dlp-ejs`.
# Sin un runtime de JS instalado, yt-dlp tiene el script pero nada con qué
# ejecutarlo, y el fallo es SILENCIOSO (el servidor corre con quiet=True):
# `/resolve` sigue funcionando y sólo `/audio` devuelve 403. Esa fue
# exactamente la avería del 2026-08-17; la ejecución nativa ya lo tenía
# resuelto porque el PC de desarrollo tiene Node instalado, pero esta imagen
# no — nunca se llegó a correr el camino Docker (CLAUDE.md, Etapa 9).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Sin privilegios: este servicio habla con internet y ejecuta un extractor
# que cambia cada semana.
RUN useradd --system --create-home --uid 10001 heardy \
    && mkdir -p /data/cache \
    && chown -R heardy:heardy /data
USER heardy

# Los valores por defecto de config.py están pensados para ejecución nativa
# (caché junto al proyecto, loopback). Dentro del contenedor hay que
# sobreescribirlos: el volumen está en /data y hay que escuchar en todas las
# interfaces para que el mapeo de puertos de compose llegue a algo.
ENV HEARDY_CACHE_DIR=/data/cache \
    HEARDY_HOST=0.0.0.0 \
    HEARDY_PORT=8080 \
    PYTHONUNBUFFERED=1

EXPOSE 8080

HEALTHCHECK --interval=60s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import os,urllib.request,sys; p=os.environ.get('PORT','8080'); sys.exit(0 if urllib.request.urlopen(f'http://127.0.0.1:{p}/health', timeout=4).status==200 else 1)"

# Forma shell a propósito, no exec: las PaaS tipo Render/Cloud Run inyectan el
# puerto a escuchar en la variable PORT y esperan que el proceso la respete —
# con el 8080 fijo de antes, el servicio arrancaba pero la plataforma lo daba
# por caído porque nadie escuchaba donde ella miraba. El `:-8080` mantiene
# intacto el comportamiento de docker-compose, que no define PORT.
CMD uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080}
