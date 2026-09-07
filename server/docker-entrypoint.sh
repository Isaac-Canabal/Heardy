#!/bin/sh
# Arranca el proveedor de PO tokens como sidecar DENTRO de este contenedor y
# después la API, que es el proceso que manda.
#
# Por qué existe este script. El Dockerfile ofrecía dos modos y para una PaaS
# gratuita se había elegido el "script mode", razonando que esas plataformas
# sólo dan UN servicio siempre encendido. El razonamiento confundía "un
# servicio" con "un proceso": el sidecar cabe perfectamente en el mismo
# contenedor.
#
# Y la diferencia no es de matiz. En script mode el plugin lanza un proceso
# Node NUEVO por cada token, y antes comprueba que responde
# (`node generate_once.js --version`) con un plazo de 15 s que fija él mismo.
# Con ~0,1 vCPU, arrancar Node no entra en ese plazo: `subprocess.TimeoutExpired`
# subía sin traducir hasta FastAPI y la app recibía un 500 opaco sobre vídeos
# perfectamente sanos. En modo sidecar, Node arranca UNA vez, se queda caliente
# y cada token es una petición HTTP a loopback.
#
# `exec` para la API a propósito: así uvicorn hereda el PID 1 y recibe
# directamente el SIGTERM con el que la plataforma para el contenedor, sin un
# shell intermedio que se lo coma.
set -e

# --max-old-space-size acota el heap de V8. Sin límite, Node dimensiona su
# heap contra la memoria de la MÁQUINA, no contra la del contenedor, y en un
# plan de 512 MB compartidos con Python + yt-dlp eso termina en un reinicio por
# exceso de memoria. El proveedor sólo genera tokens: 96 MB le sobran.
if [ -f /opt/bgutil-server/build/main.js ]; then
    echo "Arrancando el proveedor de PO tokens (sidecar en este contenedor)..."
    node --max-old-space-size=96 /opt/bgutil-server/build/main.js &
else
    # No se aborta el arranque: sin proveedor, /resolve y la búsqueda siguen
    # funcionando y /health lo reporta como inalcanzable, que es información
    # útil. Abortar dejaría el servicio entero caído por una mitad.
    echo "[AVISO] No está /opt/bgutil-server/build/main.js: sin proveedor de PO tokens."
fi

exec uvicorn app.main:app --host 0.0.0.0 --port "${PORT:-8080}"
