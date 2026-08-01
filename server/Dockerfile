FROM python:3.12-slim

# ffmpeg no está en la ruta normal (DD4: nunca se recodifica), pero yt-dlp lo
# usa para remuxear cuando el formato llega en fragmentos DASH separados, que
# es una parte legítima de "entregar el AAC original intacto".
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
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

ENV HEARDY_CACHE_DIR=/data/cache \
    PYTHONUNBUFFERED=1

EXPOSE 8080

HEALTHCHECK --interval=60s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=4).status==200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
