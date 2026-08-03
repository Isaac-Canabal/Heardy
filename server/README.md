# Heardy — servidor de descargas

API HTTP que Heardy consume para importar audio de YouTube a la biblioteca
local. La app **no** extrae nada por su cuenta: toda la fragilidad frente a
YouTube vive aquí, donde se arregla actualizando una dependencia en vez de
publicando una release en Play Store.

Ver `../CLAUDE.md` (sección "YouTube downloads", DD1) para por qué existe
este servicio en lugar de un extractor embebido.

Hay **dos formas de levantarlo** y son intercambiables: nativa con Python
(para desarrollar y probar, es la de abajo) y Docker (para dejarlo corriendo,
al final del documento). Ninguna necesita de la otra.

---

## Requisitos previos (Windows)

| Qué | Para qué | Cómo instalarlo | Obligatorio |
|---|---|---|---|
| **Python 3.10+** | La API | [python.org/downloads](https://www.python.org/downloads/) — marcá **"Add python.exe to PATH"** durante la instalación | Sí |
| **Node.js LTS** | El proveedor de PO tokens es una app Node | [nodejs.org](https://nodejs.org/) (versión LTS) | Sí |
| **Git** | Clonar el proveedor | [git-scm.com/download/win](https://git-scm.com/download/win) | Sí |
| **ffmpeg** | Remuxear cuando YouTube sirve el audio en fragmentos DASH separados | `winget install Gyan.FFmpeg` o desde [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) | Recomendado |

**Sobre ffmpeg:** no se usa para recodificar — eso está prohibido por diseño
(DD4, el audio se entrega tal cual). Hace falta solo cuando yt-dlp recibe la
pista partida en fragmentos y tiene que volver a unirlos en un `.m4a`. Sin él
la mayoría de vídeos funcionan igual, pero algunos fallarán con un error de
posprocesado. Después de instalarlo, **cerrá y volvé a abrir la terminal**
para que el PATH se actualice.

Comprobá que los tres obligatorios responden antes de seguir:

```bat
py --version
node --version
git --version
```

---

## Instalación

Una sola vez, desde `server\`:

```bat
setup.bat
```

Eso hace cuatro cosas:

1. comprueba Python;
2. crea el entorno virtual en `server\.venv\`;
3. instala `requirements.txt` (FastAPI, uvicorn, yt-dlp y el plugin de PO tokens);
4. clona y compila el proveedor de PO tokens en `server\.pot-provider\`.

El paso 4 merece una nota: el proveedor tiene **dos mitades cuyas versiones
deben coincidir** — el plugin de yt-dlp (pip) y el servidor HTTP (Node).
`setup.bat` lee la versión del plugin instalado y clona el servidor en esa
misma etiqueta. Un desajuste entre ambas es el fallo silencioso más probable
de todo el montaje: el servidor arranca, `/health` dice que el proveedor
responde, y las descargas fallan igual con 403.

Después, generá la clave de API:

```bat
make-key.bat
```

Escribe una clave aleatoria en `server\.env` y la imprime. Ese valor es el que
va en **Ajustes → Servidor de descargas** de la app. (`server\.env` está en
`.gitignore`; no se comitea.)

---

## Uso diario

```bat
run.bat
```

Levanta el proveedor de PO tokens en una ventana aparte y la API en la actual.
Dejá las dos abiertas. `Ctrl+C` para la API; cerrá la otra ventana para parar
el proveedor.

Si preferís controlarlas por separado:

```bat
run-pot.bat      REM solo el proveedor de PO tokens  (http://127.0.0.1:4416)
run-api.bat      REM solo la API                      (http://127.0.0.1:8080)
```

### Comprobar que funciona

```bat
health.bat
```

Debe decir `[OK]` en las cuatro líneas. Lo importante es
**`Proveedor de PO tokens responde`**: si eso falla, la API arranca igual pero
casi todas las descargas devolverán 403.

Para probar la cadena entera contra YouTube de verdad:

```bat
health.bat --url https://www.youtube.com/watch?v=jNQXAC9IVRw
health.bat --url https://www.youtube.com/watch?v=jNQXAC9IVRw --audio
```

`--audio` baja el archivo a un temporal y comprueba que es un contenedor MP4
válido. `health.bat` sin `--url` no toca YouTube en absoluto, así que podés
ejecutarlo tantas veces como quieras; con `--url` sí gasta presupuesto de IP,
que es el recurso escaso de todo esto.

### Conectar la app

Por defecto la API escucha solo en `127.0.0.1`, así que desde el móvil no se
llega. Dos opciones:

- **Tailscale** (recomendado): instalalo en el PC y en el móvil, y apuntá la
  app a `100.x.y.z:8080`. Cifrado, no expone nada a internet, y funciona
  también fuera de casa.
- **LAN de casa**: poné `HEARDY_HOST=0.0.0.0` en `server\.env`, reiniciá, y
  usá la IP local del PC (`ipconfig`). Puede que haya que permitir el puerto
  en el Firewall de Windows la primera vez.

En ambos casos la app hablará por `http://`, y Android bloquea el tráfico en
claro por defecto — la app ya trae un `network_security_config.xml` que lo
permite para rangos privados y para Tailscale.

**No expongas este servicio a internet abierto.** La clave de API es lo único
que lo protege.

---

## Endpoints

Todos menos `/health` requieren la cabecera `X-Api-Key`.

| Método | Ruta | Devuelve |
|---|---|---|
| `GET` | `/health` | versión de yt-dlp, estado del proveedor de PO tokens, estado de la caché. **Sin autenticación**, para que la app pueda distinguir "servidor apagado" de "clave incorrecta" |
| `POST` | `/resolve` | `{id, title, artist, album, durationSeconds, thumbnailUrl, sourceUrl}`. Cuerpo: `{"url": "…"}` |
| `POST` | `/playlist` | `{id, name, sourceUrl, entries:[…]}`. Cuerpo: `{"url": "…"}` |
| `GET` | `/search?q=&limit=` | `{results:[…]}` |
| `GET` | `/audio/{videoId}` | los bytes M4A. Soporta `Range` |
| `DELETE` | `/cache` | vacía la caché de audio |

También hay documentación interactiva en `http://127.0.0.1:8080/docs`.

---

## Claves por usuario y límite de peticiones

Pensado para el **servidor oficial** compartido por varias personas — un
servidor personal de un solo usuario no necesita nada de esto y sigue
funcionando exactamente igual con solo `HEARDY_API_KEY`. Ver
`../docs/arquitectura_servidor_hibrido.md` (secciones 5 y 6) para el
porqué.

**Varias claves con nombre** (`HEARDY_API_KEYS` en `.env`, formato
`etiqueta:clave,etiqueta:clave,...`): cada persona tiene la suya, así se
puede revocar el acceso de una sin rotar la de las demás, y los logs de la
API (`/resolve por isaac: ...`) dicen quién generó cada petición. Convive
sin conflicto con `HEARDY_API_KEY` — si están las dos, ambas claves son
válidas.

**Límite de peticiones** (`HEARDY_RATE_LIMIT_PER_KEY`,
`HEARDY_RATE_LIMIT_WINDOW_SECONDS`, `HEARDY_DAILY_QUOTA` en `.env`,
todos en 0 = desactivado por defecto): protege el presupuesto de IP
compartido frente a YouTube, tanto de abuso como de que los propios
usuarios lo agoten entre todos en poco tiempo. Al superarlo, la API
responde `429` con una cabecera `Retry-After` calculada a partir de la
propia ventana — nunca un número inventado. Solo se aplica a los cuatro
endpoints que le cuestan presupuesto a la IP (`/resolve`, `/playlist`,
`/search`, `/audio`); `/cache` no lo necesita, es puramente local.

---

## Tests

```bat
test.bat
```

Corre la suite de `pytest` (`server\tests\`). La primera vez crea su propio
`.venv` e instala `requirements-dev.txt` — deliberadamente más liviano que
`requirements.txt`, porque los tests son de lógica pura (`auth.py`,
`config.py`, `rate_limit.py`) y no necesitan yt-dlp ni el proveedor de PO
tokens instalados. No toca YouTube ni el `.venv` de `run.bat`/`setup.bat`.

---

## Diagnóstico

| Síntoma | Causa probable |
|---|---|
| `health.bat` dice que no hay nadie escuchando | La API no está arrancada: `run.bat` |
| `Proveedor de PO tokens NO responde` | Falta `run-pot.bat`, o su ventana se cerró |
| 401 desde la app | La clave de Ajustes no coincide con ninguna de `HEARDY_API_KEY`/`HEARDY_API_KEYS` de `server\.env`. Tras cambiar el `.env` hay que reiniciar la API |
| 403 / "Sign in to confirm you're not a bot" | El proveedor de PO tokens está caído, o su versión no coincide con la del plugin. Volvé a ejecutar `setup.bat` |
| 415 | Ese vídeo no tiene pista AAC/M4A. Es definitivo para ese vídeo, no un fallo del servidor |
| 429 | Se agotó el límite de peticiones (por clave o el tope diario global). Trae `Retry-After` con los segundos exactos — solo pasa si `HEARDY_RATE_LIMIT_PER_KEY`/`HEARDY_DAILY_QUOTA` están configurados |
| Error de posprocesado al descargar | Falta ffmpeg en el PATH |
| `node` o `git` no reconocidos en `setup.bat` | Instalados pero sin reabrir la terminal |

Los errores de extracción salen como HTTP 502 con el mensaje de yt-dlp
íntegro, para no perder información por el camino.

---

## Mantenimiento

Esto es lo que hay que hacer periódicamente, y es todo:

```bat
.venv\Scripts\python.exe -m pip install --upgrade yt-dlp bgutil-ytdlp-pot-provider
.venv\Scripts\python.exe tools\setup_pot.py
```

La segunda línea vuelve a alinear el servidor Node con la versión del plugin
que se acaba de actualizar. **No te saltes ese paso**: actualizar solo una de
las dos mitades es exactamente cómo se acaba con 403 en todas las descargas.

`yt-dlp` está deliberadamente **sin fijar** en `requirements.txt`, al
contrario que el resto de dependencias: es la única pieza cuyo valor está en
ser la más nueva posible. Fijar su versión es cómo se acaba con un servidor
que dejó de funcionar sin que nadie tocara nada.

---

## Despliegue con Docker (opcional)

Para dejarlo corriendo permanentemente, sin ventanas de terminal abiertas.
**No hace falta para desarrollar ni probar** — todo lo de arriba funciona sin
Docker.

**Ponelo en una IP residencial** —un PC de casa, una Raspberry Pi, un NAS—,
no en un VPS. Las IPs de datacenter (Railway, Hetzner, DigitalOcean…) se
bloquean mucho más rápido; así fue como bloquearon la instancia pública de
Cobalt. Además sale gratis.

```bash
cd server
cp .env.example .env     # y poné HEARDY_API_KEY
docker compose up -d --build
curl -s localhost:8080/health
```

`docker-compose.yml` levanta las dos mitades como servicios separados y las
conecta por la red interna, así que no hay que arrancar nada a mano. Las
variables de entorno del `Dockerfile` sobreescriben los valores por defecto
de `config.py`, que están pensados para ejecución nativa.

Actualización:

```bash
docker compose build --pull --no-cache   # trae la última yt-dlp
docker compose pull                      # actualiza el sidecar de PO tokens
docker compose up -d
```

### Despliegue oficial (PC propio + Tailscale Funnel)

**Actualización 2026-08-03: se abandonó Oracle Cloud** (fricción de
verificación de cuenta, tanto en Oracle como en Google Cloud — exactamente
el riesgo que ya nombraba `../docs/arquitectura_servidor_hibrido.md` sección
9.3). El servidor oficial pasa a correr en un PC de casa, igual que
cualquier servidor personal — **no hay una segunda implementación, ni
siquiera una segunda forma de arrancarla**: es el mismo
`docker compose up -d` de siempre.

Lo único que cambia es cómo se hace público: **Tailscale Funnel** expone el
puerto `127.0.0.1:8080` de `heardy-dl` a internet con HTTPS automático (TLS
de Tailscale, no Let's Encrypt/Caddy), sin abrir puertos en el router:

```bash
cd server
cp .env.example .env     # HEARDY_API_KEYS con una clave por persona, ver arriba
docker compose up -d --build
tailscale funnel 8080
```

`tailscale funnel status` muestra el hostname público
(`https://<máquina>.<tailnet>.ts.net`) — es el mismo hostname para siempre
mientras no cambies de máquina, así que va directo a
`lib/services/official_server.dart` como valor por defecto de
`OfficialServer.url`. `tailscale funnel` corre en el host, no en un
contenedor — no toca `docker-compose.yml`.

Con esto la IP de salida hacia YouTube es residencial, no de datacenter —
justo la condición que la sección 1 de `arquitectura_servidor_hibrido.md`
identifica como la que menos choca con el muro anti-bot. El costo real es
el que ya se sabía: solo responde mientras el PC esté encendido.

---

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
  sin dar throughput real. Medido en `../docs/investigacion_muro_antibot.md`.
- **Caché LRU en disco.** El recurso escaso no es el disco, es el presupuesto
  de peticiones por IP. Un reintento tras un corte de red debe salir del
  disco. Medido: una segunda petición del mismo audio tarda ~0,4 s.
- **La caché baja a `.part-download` y renombra al final**, para que una
  descarga interrumpida no deje un archivo truncado que la siguiente petición
  dé por bueno.
- **El servidor oficial es exactamente el mismo `docker compose up -d` que
  cualquier servidor personal.** Ya no hay Caddy ni un perfil `official` en
  `docker-compose.yml` — la única diferencia entre "personal" y "oficial" es
  que el segundo además corre `tailscale funnel 8080` en el host para ser
  público. Una sola implementación de backend, cero ramas de despliegue.
- **`/search` usa `extract_flat`**, una sola petición para N resultados en vez
  de una por vídeo. El coste es que `artist` sale del nombre del canal, que
  para un canal de recopilaciones no es el artista real. Por eso la app debe
  llamar a `/resolve` sobre el resultado elegido antes de descargarlo, y no
  quedarse con la metadata de la búsqueda.
