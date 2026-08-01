# Heardy — servidor de descargas

API HTTP que Heardy consume para importar audio de YouTube a la biblioteca
local. La app **no** extrae nada por su cuenta: toda la fragilidad frente a
YouTube vive aquí, donde se arregla con un `docker compose pull` en vez de
con una release en Play Store.

Ver `../CLAUDE.md` (sección "YouTube downloads", DD1) para por qué existe
este servicio en lugar de un extractor embebido.

## Despliegue

**Ponlo en una IP residencial** — un PC de casa, una Raspberry Pi, un NAS —,
no en un VPS. Las IPs de datacenter (Railway, Hetzner, DigitalOcean…) se
bloquean mucho más rápido; así fue como bloquearon la instancia pública de
Cobalt. Además sale gratis.

```bash
cd server
cp .env.example .env
openssl rand -hex 32          # pega el resultado en HEARDY_API_KEY
docker compose up -d --build
```

Comprueba que arrancó bien:

```bash
curl -s localhost:8080/health | python -m json.tool
```

`potProvider.reachable` debe ser `true`. Si es `false`, el sidecar de PO
Tokens no está levantado y YouTube devolverá 403 en la mayoría de vídeos.

## Acceso desde el móvil

Por defecto el puerto solo escucha en `127.0.0.1`, así que desde el teléfono
no se llega. Lo recomendado es [Tailscale](https://tailscale.com/): instálalo
en el servidor y en el móvil, y apunta la app a la IP `100.x.y.z` del
servidor. Es cifrado, no expone nada a internet y funciona igual fuera de
casa.

Si prefieres solo la LAN de casa, cambia el mapeo de puertos en
`docker-compose.yml` a `"8080:8080"` y usa la IP local del servidor. En ese
caso la app hablará por `http://`, y Android bloquea el tráfico en claro por
defecto — la app ya trae un `network_security_config.xml` que lo permite para
rangos privados.

No expongas este servicio a internet abierto. La clave de API es lo único que
lo protege.

## Mantenimiento

Esto es lo que hay que hacer periódicamente, y es todo:

```bash
cd server
docker compose build --pull --no-cache   # trae la última yt-dlp
docker compose pull                      # actualiza el sidecar de PO tokens
docker compose up -d
curl -s localhost:8080/health
```

`yt-dlp` está deliberadamente **sin fijar** en `requirements.txt`, al
contrario que el resto de dependencias: es la única pieza cuyo valor está en
ser la más nueva posible. Fijar su versión es exactamente cómo se acaba con
un servidor que dejó de funcionar sin que nadie tocara nada.

Si algo falla, `docker compose logs -f heardy-dl` y `GET /health` son el
punto de partida. Los errores de extracción salen como HTTP 502 con el
mensaje de yt-dlp íntegro.

## Endpoints

Todos menos `/health` requieren la cabecera `X-Api-Key`.

| Método | Ruta | Devuelve |
|---|---|---|
| `GET` | `/health` | versión de yt-dlp, estado del proveedor de PO tokens, estado de la caché. **Sin autenticación**, para que la app pueda distinguir "servidor apagado" de "clave incorrecta" |
| `POST` | `/resolve` | `{id, title, artist, album, durationSeconds, thumbnailUrl, sourceUrl}` para un vídeo. Cuerpo: `{"url": "…"}` |
| `POST` | `/playlist` | `{id, name, sourceUrl, entries:[…]}`. Cuerpo: `{"url": "…"}` |
| `GET` | `/search?q=&limit=` | `{results:[…]}` |
| `GET` | `/audio/{videoId}` | los bytes M4A. Soporta `Range` |
| `DELETE` | `/cache` | vacía la caché de audio |

```bash
KEY=$(grep HEARDY_API_KEY .env | cut -d= -f2)

curl -s -X POST localhost:8080/resolve \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d '{"url":"https://www.youtube.com/watch?v=..."}' | python -m json.tool

curl -s -o prueba.m4a -D- localhost:8080/audio/... -H "X-Api-Key: $KEY"
ffprobe prueba.m4a        # debe decir aac, sin recodificar
```

## Decisiones que no son accidentes

- **Formato `bestaudio[ext=m4a]`, nunca recodificado.** Es lo que la app ya
  sabe indexar (`m4a` está en `AudioIdentityService.audioExtensions`) y cuyos
  tags sabe escribir. Un vídeo sin pista AAC devuelve **415**, no un WebM
  sorpresa: 415 es definitivo y el cliente no lo reintenta, mientras que un
  502 sí.
- **`/audio` bloquea** mientras yt-dlp baja (3–15 s típicos) en vez de usar
  un modelo job+polling. Más simple; el coste es que la app muestra
  "Preparando…" antes de que haya progreso por bytes. Migrar a jobs sería
  aditivo.
- **Concurrencia 2 por defecto.** El muro de YouTube es un presupuesto
  acumulado por IP, no un límite de tasa: la concurrencia lo gasta más rápido
  sin dar throughput real. Medido en `docs/investigacion_muro_antibot.md`.
- **Caché LRU en disco.** El recurso escaso no es el disco, es el presupuesto
  de peticiones por IP. Un reintento tras un corte de red debe salir del
  disco.
- **La caché baja a `.part-download` y renombra al final**, para que una
  descarga interrumpida no deje un archivo truncado que la siguiente petición
  dé por bueno.
