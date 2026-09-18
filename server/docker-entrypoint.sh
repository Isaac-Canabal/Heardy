#!/bin/sh
# Arranca la API y, sólo si se pidió, el proveedor de PO tokens como sidecar
# DENTRO de este contenedor.
#
# Por defecto NO se levanta el sidecar: la imagen usa el "script mode" del
# proveedor (HEARDY_POT_PROVIDER_SCRIPT_HOME en el Dockerfile), que lanza Node
# sólo cuando caduca el token cacheado y no deja ningún proceso residente. La
# razón es memoria, medida en producción: en 512 MB, un sidecar Node de
# ~100-150 MB siempre encendido más el Node transitorio con el que yt-dlp
# resuelve el "n challenge" (que la primera vez tras cada arranque parsea el
# player entero de YouTube) no caben juntos, y la plataforma reiniciaba el
# servicio en mitad de cada descarga. Ver la cabecera del Dockerfile.
#
# HEARDY_POT_SIDECAR=1 elige el sidecar HTTP en loopback (config.py anula el
# script mode al verla): más rápido por token, para instancias con más RAM.
#
# `exec` para la API a propósito: así uvicorn hereda el PID 1 y recibe
# directamente el SIGTERM con el que la plataforma para el contenedor, sin un
# shell intermedio que se lo coma.
set -e

if [ "${HEARDY_POT_SIDECAR:-0}" = "1" ]; then
    if [ -f /opt/bgutil-server/build/main.js ]; then
        # --max-old-space-size acota el heap de V8. Sin límite, Node dimensiona
        # su heap contra la memoria de la MÁQUINA, no contra la del contenedor.
        # El proveedor sólo genera tokens: 96 MB le sobran.
        echo "Arrancando el proveedor de PO tokens (sidecar en este contenedor)..."
        node --max-old-space-size=96 /opt/bgutil-server/build/main.js &
    else
        # No se aborta el arranque: sin proveedor, /resolve y la búsqueda
        # siguen funcionando y /health lo reporta como inalcanzable, que es
        # información útil. Abortar dejaría el servicio entero caído por una
        # mitad.
        echo "[AVISO] No está /opt/bgutil-server/build/main.js: sin proveedor de PO tokens."
    fi
fi

exec uvicorn app.main:app --host 0.0.0.0 --port "${PORT:-8080}"
