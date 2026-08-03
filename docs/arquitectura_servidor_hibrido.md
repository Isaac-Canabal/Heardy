# Arquitectura híbrida del servidor de descargas (oficial + personalizado)

> Documento de arquitectura, agosto 2026. Ver `CLAUDE.md`, sección "YouTube
> downloads", para el estado real del código en `feature/youtube-downloads`.

## Actualización 2026-08-03 — Oracle Cloud descartado, PC propio + Tailscale Funnel en su lugar

Las secciones 2 y 3 de abajo recomendaban Oracle Cloud Always Free y quedan
como registro de por qué se llegó ahí, pero **no son la decisión vigente**.
En la práctica no se pudo dar de alta ni Oracle Cloud ni Google Cloud —
fricción de verificación de cuenta, exactamente el riesgo que la sección
9.3 ya nombraba antes de intentarlo (*"Oracle es conocido por fricciones de
verificación"*).

La alternativa elegida es la fila **"Servidor casero + túnel"** de la tabla
comparativa (sección 2) — descartada en su momento por preferencia de
"quiero nube, no casero", no por ningún motivo técnico. Con **Tailscale
Funnel** como mecanismo de túnel (HTTPS público automático, sin abrir
puertos ni tocar el router; ya recomendado en `server/README.md` para uso
personal):

- **Es técnicamente mejor contra el hallazgo de la sección 1, no peor.** La
  IP de salida hacia YouTube pasa a ser residencial — la única categoría
  que la sección 1 mide sin el problema de bloqueo elevado de las IPs de
  datacenter. Todas las mitigaciones ahí descritas (rate limiting, caché,
  PO-provider sincronizado) se quedan, pero ahora atacan un problema que ya
  era más raro de por sí.
- **El costo real es el que ya se sabía de entrada:** el servidor oficial
  solo responde mientras el PC de casa esté encendido. Aceptado
  explícitamente por decisión del usuario.
- **Caddy + DuckDNS (sección 3) ya no existen** — `server/docker-compose.yml`
  no tiene servicio `caddy` ni perfil `official`; el servidor oficial es
  literalmente el mismo `docker compose up -d` que cualquier servidor
  personal. Tailscale Funnel corre en el host, no en un contenedor, y da su
  propio TLS — no hace falta Let's Encrypt ni un hostname de DNS dinámico.
- **`OfficialServer.url`** (`lib/services/official_server.dart`) apunta al
  hostname que asigna Tailscale Funnel (`https://<máquina>.<tailnet>.ts.net`,
  ver `tailscale funnel status`), no a un dominio DuckDNS.

El resto de este documento (secciones 1, 5, 6, 7, 9) sigue vigente sin
cambios — rate limiting, claves por usuario, y el análisis del muro
anti-bot no dependen de qué proveedor aloja la VM/PC. Solo las secciones 2
(comparativa) y 3 (recomendación Oracle+Caddy+DuckDNS) quedan como registro
histórico de una decisión que no sobrevivió el contacto con la realidad.

## Contexto

Hoy `feature/youtube-downloads` asume que **cada usuario levanta su propio
servidor** (`server/`, FastAPI + yt-dlp + proveedor de PO tokens), apuntado
manualmente desde Ajustes. Eso es coherente con DD1 (el servidor existe para
que la fragilidad frente a YouTube se arregle actualizando una dependencia,
no publicando una release) pero le pone a cualquier usuario nuevo una barrera
de entrada real: Python, Docker, un PC encendido.

El objetivo de este documento es diseñar cómo la app puede funcionar **sin
que el usuario promedio configure nada** (un servidor oficial mantenido por
el proyecto, usado por defecto) sin dejar de soportar el modo actual para
usuarios avanzados — con **una sola implementación de backend** para ambos
casos.

**Decisiones ya tomadas para este documento** (respondidas antes de
redactarlo, no se reabren aquí):
- El servidor oficial va en **nube**, no en un equipo casero.
- Presupuesto del servidor oficial: **estrictamente $0** recurrente.
- Alcance: **grupo cerrado de ~5 personas conocidas** (beta privada), no
  publicación amplia en Play Store todavía.

---

## 1. El hallazgo central: por qué "nube gratis" no es una decisión trivial aquí

Antes de comparar plataformas hay que nombrar la tensión que domina todo lo
demás. **No es hipotética — ya está medida y documentada en este mismo
repositorio:**

- `docs/investigacion_muro_antibot.md`: el presupuesto de peticiones de
  manifest por IP se midió en **~12-24** antes de chocar con el muro
  ("Sign in to confirm you're not a bot"), con una ventana de recuperación
  de **20-40+ minutos, no un número fijo**.
- `server/README.md`, sección Docker (ya escrita, antes de este documento):
  *"Ponelo en una IP residencial —un PC de casa, una Raspberry Pi, un
  NAS—, no en un VPS. Las IPs de datacenter (Railway, Hetzner,
  DigitalOcean…) se bloquean mucho más rápido; así fue como bloquearon la
  instancia pública de Cobalt."*
- Investigación externa (agosto 2026) confirma que esto sigue vigente: las
  IPs de datacenter de AWS/GCP/Azure/Oracle/etc. están en listas de
  reputación conocidas por YouTube, y un caso reportado midió ~9% de tasa
  de bloqueo en una IP de nube marcada frente a <1% en las no marcadas, con
  el mismo código y versión de yt-dlp.

**Consecuencia directa de "quiero nube, no casero":** el servidor oficial va
a chocar con el muro anti-bot con más frecuencia que si estuviera en una IP
residencial — eso no es un riesgo remoto, es el resultado esperable de la
propia decisión, y el resto de este documento (rate limiting, UX de cuota,
caché agresiva, fallback a servidor personal) existe en gran parte para
convivir con esa realidad, no para eliminarla. Se puede mitigar, no
evitar del todo dentro del presupuesto de $0.

Esto **no invalida** la decisión — con un grupo cerrado de 5 personas hay
una salida de emergencia trivial que un despliegue público no tendría:
"cambiá a tu propio servidor" es una opción real cuando conocés a los 5
usuarios, no una frase vacía.

---

## 2. Comparativa de plataformas gratuitas (agosto 2026)

| Plataforma | Costo | ¿Siempre encendido? | Disco persistente | Docker Compose (2 procesos: API + PO-provider) | Ancho de banda | Estabilidad del free tier | IP |
|---|---|---|---|---|---|---|---|
| **Oracle Cloud Always Free** | $0 | Sí, VM completa 24/7 | Sí, 200 GB block volume | Sí, sin restricciones — es una VM real | 10 TB/mes salida | Recortó Ampere A1 de 4 OCPU/24GB a 2 OCPU/12GB en jun-2026 **sin aviso público**; sigue siendo generoso para esta carga, pero no es garantía a futuro | Datacenter |
| **Render (free)** | $0 | **No** — duerme a los 15 min de inactividad, cold start 30-60s | **No** — free tier no tiene disco persistente, se borra en cada redeploy/restart | Parcial — el disco efímero rompe tanto la caché LRU como cualquier estado del proveedor de PO tokens | No especificado con precisión, limitado | Estable como política, pero el sleep y la falta de disco lo descartan por diseño | Datacenter |
| **Railway** | Ya no es realmente gratis | Depende del crédito | Sí (pago) | Sí | Según crédito consumido | Cambió en 2023-2024: hoy es $5 de crédito único (30 días) + $1/mes de "free plan" — no alcanza para un servicio siempre encendido | Datacenter |
| **Fly.io** | Ya no tiene free tier | — | — | — | — | Eliminó las asignaciones gratuitas permanentes en 2024; hoy son 2h de prueba y luego todo se factura | Datacenter |
| **Google Cloud Run** | $0 hasta 2M requests/mes, pero... | Con `min-instances=1` dejás de estar en el free tier real (se factura memoria/CPU idle) | Necesita Filestore u otro servicio pago para disco persistente compartido entre contenedores | Soporta sidecars, pero el caso de uso (proceso Node siempre vivo + caché en disco) empuja fuera del free tier | Incluido hasta la cuota | Estable, pero no es realmente "siempre encendido gratis" para este caso | Datacenter |
| **Koyeb (free)** | $0 | **No** — duerme tras 1h sin tráfico, no se puede desactivar en el plan gratuito | No permite volúmenes en el plan gratuito | No — 1 solo servicio web, no soporta el segundo proceso (PO-provider) sin plan de pago | Limitado | Política clara pero muy restrictiva | Datacenter |
| **Servidor casero + túnel** *(descartada por decisión del usuario, incluida para que quede documentada la comparación)* | $0 | Depende de tu casa (luz/internet) | Sí, tu propio disco | Sí, sin cambios — es exactamente el Docker Compose actual de `server/` | El tuyo, sin límite de proveedor cloud | Tan estable como tu conexión residencial | **Residencial** — la única opción sin el problema de la sección 1 |

**Conclusión de la comparativa:** de las cuatro plataformas evaluadas
explícitamente, **solo Oracle Cloud Always Free sigue siendo gratis de
verdad y da una VM completa** capaz de correr el `docker-compose.yml` que
ya existe sin modificarlo (dos contenedores, disco persistente, sin
sleep). Render, Railway, Fly.io y Koyeb quedan descartadas — no por ser
peores en el problema anti-bot (todas son datacenter, ninguna resuelve la
sección 1), sino porque **ni siquiera cumplen el requisito básico de
"gratis y siempre encendido con dos procesos y disco"** que esta carga de
trabajo necesita.

---

## 3. Recomendación: Oracle Cloud Always Free + Caddy + DuckDNS

**Desplegar el `server/` actual, tal cual, en una VM Ampere A1 (ARM) de
Oracle Cloud Always Free**, con un único añadido de infraestructura:

- Un contenedor **Caddy** más en el mismo `docker-compose.yml`, como reverse
  proxy delante de `heardy-dl`, para TLS automático y gratuito vía Let's
  Encrypt.
- Un hostname gratuito de **DuckDNS** (`heardy-oficial.duckdns.org` o
  similar) apuntando a la IP pública de la VM — Oracle asigna una IP
  pública real a la instancia, así que **no hace falta túnel** (Tailscale
  Funnel/Cloudflare Tunnel existen para esquivar NAT/CGNAT, que es el
  problema de una IP casera, no el de una VM en la nube). Esto evita el
  único costo real de la alternativa con dominio propio (~9€/año).

Por qué esta combinación y no otra:
- **Cero cambios al backend.** Mismo `Dockerfile`, mismo
  `docker-compose.yml` (solo se le agrega el servicio Caddy), mismo
  `config.py`. Cumple directamente el requisito de "no mantener dos
  implementaciones distintas".
- **ARM vs x86:** yt-dlp y Python corren nativamente en ARM sin problema;
  ffmpeg tiene build ARM oficial. Sin fricción esperable.
- **200 GB de disco persistente** es más que suficiente para la caché LRU
  (`CACHE_MAX_BYTES` hoy en 2048 MB) incluso con margen amplio para crecer.
- **10 TB/mes de salida** es, para 5 usuarios descargando audio comprimido,
  un límite que no se va a rozar ni de cerca.

Mitigaciones dentro del presupuesto $0 para el hallazgo de la sección 1
(reducen la frecuencia del bloqueo, no lo eliminan):

1. **Bajar `MAX_CONCURRENT_EXTRACTIONS` a 1** en el despliegue oficial (ya
   documentado en `server/README.md`: la concurrencia gasta presupuesto de
   IP sin dar throughput real, porque es un presupuesto acumulado, no un
   límite de tasa).
2. **La caché LRU ya construida hace más trabajo aquí que en el caso de un
   solo usuario**: con 5 personas hay solapamiento real de gustos musicales
   — una canción bajada por el usuario A la sirve gratis (0 peticiones a
   YouTube) al usuario B. Esto no es nuevo código, es el mismo mecanismo ya
   verificado (~0,4s en cache-hit) rindiendo más en un escenario
   multiusuario.
3. **Rate limiting server-side deliberado** (sección 5) — no solo
   anti-abuso: sirve para que 5 personas entusiasmadas una noche no agoten
   solas el presupuesto de la única IP compartida en 20 minutos.
4. **Mantener sincronizadas las dos mitades del proveedor de PO tokens**
   (ya es un ritual de mantenimiento documentado) — es la palanca más
   fuerte que tiene yt-dlp contra el muro, independiente del tipo de IP.
5. **La salida de emergencia siempre disponible:** con un grupo cerrado y
   conocido, si el servidor oficial queda bloqueado, cualquiera de los 5
   puede levantar su propio servidor siguiendo `server/README.md` sin
   esperar a que Oracle "se recupere" — la app ya soporta cambiar de
   servidor desde Ajustes.

**Expectativa honesta a fijar, no a esconder:** el servidor oficial se va a
bloquear temporalmente con más frecuencia que un servidor casero
equivalente. Es el costo de elegir nube + $0 con este proveedor concreto.
Si en la práctica resulta intolerable, la palanca que de verdad ataca la
causa raíz —no solo mitiga el síntoma— es un proxy residencial delante del
tráfico saliente de yt-dlp (unos pocos $/mes); se documenta como opción
futura en la sección 8, no se construye ahora porque rompe el requisito de
$0.

---

## 4. Arquitectura híbrida en la app — cambio de configuración, no de diseño

La buena noticia: **el `DownloadSource`/`YtdlpServerSource` actuales no
necesitan cambiar de forma.** Ya son agnósticos a qué servidor hay detrás —
solo leen URL + clave desde `SettingsProvider`. "Modo automático" vs "modo
servidor personalizado" es una diferencia de **valores por defecto y de
dónde vive el control en la UI**, no una segunda implementación:

- `SettingsProvider` deja de tener `''` como valor por defecto de
  `download_server_url`/`download_server_api_key`; el valor por defecto
  pasa a ser la URL del servidor oficial (`https://heardy-oficial.duckdns.org`)
  y una clave de esa beta cerrada (ver sección 5 — por-usuario, no una sola
  compartida).
- La sección "Servidor de descargas" de `settings_screen.dart` (hoy
  siempre visible) se mueve dentro de un desplegable **"Ajustes
  avanzados"**, colapsado por defecto — el usuario promedio nunca lo ve.
  El botón "Probar conexión"/`probe()` no cambia: sigue siendo la misma
  llamada a `/health`, ahora simplemente contra el servidor oficial por
  defecto.
- Un botón **"Restaurar servidor oficial"** dentro de ese mismo panel,
  para volver atrás sin tener que recordar la URL/clave originales — texto
  plano en el propio panel avanzado, sin nueva infraestructura.
- Nada en `DownloadService`, `DownloadProvider`, ni en el flujo de cola
  cambia — siguen sin saber si están hablando con el servidor oficial o
  uno personalizado.

Esto significa que la "instalar → pegar URL → descargar" del modo
automático **ya funciona hoy mismo con solo cambiar los valores por
defecto** — es la superficie mínima de cambio real en la app.

---

## 5. Gestión del límite gratuito — sin inventar tiempos

Hoy `server/` **no tiene ningún rate limiting** (solo existe
`MAX_CONCURRENT_EXTRACTIONS`, que limita concurrencia, no cuota). Para un
servidor compartido por 5 personas hace falta distinguir **dos causas de
"no se puede descargar ahora"**, que son fundamentalmente distintas y no
deberían mostrarse igual:

### 5.1 Cuota propia del servidor (el proyecto se autolimita)

El servidor lleva su propio contador (ventana deslizante, por clave y un
tope diario global) para protegerse a sí mismo — tanto de abuso como de que
los propios 5 usuarios agoten el presupuesto de IP entre todos. **Esto sí
se puede conocer con exactitud**, porque lo decide el propio servidor:
responde **HTTP 429** con un header **`Retry-After`** estándar (RFC 9110),
calculado matemáticamente a partir de la ventana del limitador — nunca
inventado. Cualquier cliente HTTP sabe leer `Retry-After` de forma nativa.

### 5.2 Bloqueo de YouTube (el muro anti-bot, sección 1)

Este caso **no se puede conocer con exactitud** — la propia investigación
del repo mide la ventana de recuperación en "20-40+ minutos, no un número
fijo". Inventar un `Retry-After` preciso aquí sería mentirle al usuario.
Lo honesto es: **no fabricar una cifra falsa**, devolver un estado
distinguible (mantener el 502 actual, o pasar a 503 para separarlo
claramente de un 5xx genérico) y que el cliente muestre un rango
aproximado basado en lo medido ("puede tardar entre 20 y 40 minutos, según
lo que ya observamos"), nunca una cuenta regresiva exacta.

**Implementado 2026-08-03**, a raíz de una tanda grande (60+ canciones)
mostrando exactamente el problema que esta sección predecía: `ytdlp_client.
_classify` reconoce el mensaje del muro y lo separa en `AntiBotBlockError`
(503); el cliente lo mapea a `DownloadSourceErrorKind.antiBotBlocked` con
una espera fija de 30 minutos (dentro del rango medido, no una promesa) que
no gasta `maxAttempts` — ver CLAUDE.md, sección "Download pipeline", punto 6.

### 5.3 Cambios necesarios, a nivel de diseño (no de código todavía)

- **Nuevo valor en `DownloadSourceErrorKind`**: `quotaExceeded`, distinto
  de `extraction`. Se mapea desde el 429 de 5.1. `DownloadSourceException`
  para este caso lleva el `retryAfterSeconds` real del header — un campo
  más, no una reinvención del tipo.
- **`DownloadProvider`**: un job que falla con `quotaExceeded` no consume
  el contador de `attempts` como un fallo normal — se reprograma
  exactamente a `retryAfterSeconds` (no a la tabla de backoff fija
  `[5s, 15s, 45s]`, que es para fallos de red, no para una cuota conocida).
- **UI (banner de error / `DownloadFailure`)**: caso `quotaExceeded` con
  copy distinto y explícito ("Límite del servidor oficial alcanzado,
  probá de nuevo en X minutos") + un acceso directo a Ajustes Avanzados
  ("Usar mi propio servidor") — cumple directamente "permitir cambiar a un
  servidor personalizado si el usuario no quiere esperar". El caso del
  muro anti-bot (502/503 sin `Retry-After` fiable) usa el copy aproximado
  de 5.2 en vez de un número falso, con el mismo acceso directo.
- Ninguno de estos cambios toca `DownloadService`, `LibraryScanService` ni
  el resto de la app — quedan contenidos en `download_source.dart`,
  `ytdlp_server_source.dart`, `download_provider.dart` y las dos pantallas
  que ya leen `DownloadSourceException`/`DownloadFailure`.

---

## 6. Seguridad

- **Autenticación: seguir con `X-Api-Key`, sin rediseñar.** Para un grupo
  cerrado de 5 personas conocidas, cambiar de "una clave compartida" a
  **"una clave por persona"** es un cambio mínimo en `auth.py` (un
  diccionario `clave → etiqueta` en vez de una sola clave con
  `hmac.compare_digest`) que da tres cosas sin infraestructura nueva:
  poder revocar el acceso de una sola persona sin rotar la clave de las
  otras cuatro, saber (a nivel de logs) quién generó qué tráfico, y que el
  rate limiting de la sección 5 sea *por persona real*, no por un secreto
  compartido indistinguible. Sigue siendo la misma implementación de
  backend para servidor oficial y personalizado — un usuario avanzado con
  su propio servidor simplemente tiene una sola clave en su diccionario.
- **La clave sigue siendo un disuasivo, no un límite de seguridad fuerte**
  — viaja en el binario de la app (decompilable). Para 5 usuarios
  conocidos esto es un riesgo aceptado explícitamente, no un descuido: no
  se justifica añadir OAuth/tokens rotativos para este tamaño de
  despliegue. Si el alcance pasa a "publicación amplia" en el futuro, esta
  es la primera pieza a rediseñar.
- **Rate limiting por clave + tope diario global**, como ya se describió en
  la sección 5 — es a la vez la mitigación anti-abuso y la protección del
  presupuesto compartido de IP.
- **HTTPS obligatorio para el servidor oficial.** Al ser alcanzable desde
  redes arbitrarias (datos móviles, wifi público), no puede depender de
  las excepciones de `network_security_config.xml` (pensadas para
  `127.0.0.1`/rangos privados/Tailscale). Con Caddy + Let's Encrypt
  (sección 3) esto se resuelve automáticamente y **no hace falta tocar
  `network_security_config.xml`**: el manifest ya permite HTTPS a
  cualquier dominio por la `base-config` por defecto; las excepciones de
  cleartext siguen existiendo solo para cuando un usuario avanzado apunta
  a su propio servidor en LAN/Tailscale sin TLS, que es exactamente el
  caso para el que ya se escribieron.
- **Protección contra automatización masiva:** dentro de este alcance
  (beta cerrada, $0), el tope diario global de la sección 5 ya cubre el
  caso realista. Un CAPTCHA o un sistema de invitación con expiración
  sería sobre-ingeniería para 5 usuarios conocidos — vale la pena
  reconsiderar si el alcance cambia a Play Store pública.

---

## 7. Compatibilidad — verificación explícita

| Requisito | Se mantiene? | Cómo |
|---|---|---|
| `DownloadSource` | Sí, sin cambios de forma | Solo gana `quotaExceeded` en el enum de errores, aditivo |
| `DownloadService` | Sí, sin cambios | No sabe ni le importa qué servidor responde |
| FastAPI | Sí, sin cambios de framework | Se le añade rate limiting y (opcional) claves por usuario dentro del mismo `server/app/` |
| Docker | Sí, sigue siendo el método oficial | El despliegue oficial usa el mismo `docker-compose.yml` + un servicio Caddy nuevo |
| Ejecución manual (`setup.bat`/`run.bat`) | Sí, intacta | Nada de esto afecta el flujo de desarrollo/uso personal nativo en Windows |
| Servidor personalizado | Sí, primera clase | Es el mismo mecanismo que el oficial — un usuario avanzado apunta su propia URL/clave en el mismo panel |
| Una sola implementación de backend | Sí | El servidor oficial **es** una instancia desplegada de `server/`, no un fork ni un servicio distinto |

---

## 8. Riesgos

**Técnicos**
- El hallazgo de la sección 1 no desaparece — el servidor oficial se
  bloqueará más seguido que uno casero. Mitigado, no eliminado, dentro del
  presupuesto $0 (sección 3).
- Oracle ya demostró (jun-2026) que puede recortar el free tier sin previo
  aviso. No hay garantía contractual de que 2 OCPU/12GB/200GB se mantengan.
- El desajuste de versión entre las dos mitades del proveedor de PO
  tokens, hoy un problema que afecta a un usuario, pasa a afectar a los 5
  simultáneamente si no se sincroniza a tiempo.
- Presupuesto de IP compartido entre 5 personas: la experiencia individual
  puede ser peor que la que tiene hoy alguien con su propio servidor
  personal, incluso sin contar el problema de datacenter.

**Mantenimiento**
- Pasa de "herramienta de desarrollo local" a "servicio que otras 4
  personas dependen de que sigas manteniendo" — implica revisar logs de
  abuso, mantener yt-dlp/PO-provider al día con una cadencia que ahora
  afecta a terceros, y estar disponible para "el servidor está caído"
  aunque sea una beta cerrada entre conocidos.

**Legales**
- Descargar audio de YouTube para escucha offline personal ya vive en una
  zona gris según jurisdicción y los propios ToS de YouTube. **Operar un
  servicio compartido que lo hace en nombre de terceros —aunque sean 5
  personas conocidas— es una postura distinta a que cada quien lo haga
  para sí mismo**: quien mantiene el servidor pasa a ser quien ejecuta la
  extracción, no solo quien distribuye el software. No es un análisis
  legal, es un riesgo a nombrar explícitamente antes de decidir operar
  esto para otros, incluso a pequeña escala. Vale la pena una consulta
  real si esto preocupa, especialmente antes de ampliar el alcance más
  allá de la beta cerrada.

**Costos futuros**
- Servidor casero: $0 indefinido, solo electricidad/ancho de banda propios.
- Oracle Always Free: $0 hoy, con precedente de reducción unilateral —
  hay que estar dispuesto a migrar si Oracle lo recorta más o lo retira.

**Migración a VPS pagado sin tocar la app — confirmado que ya funciona así**
El "servidor oficial" no es más que una URL+clave por defecto en
`SettingsProvider`. Mover el despliegue de Oracle a un VPS pagado (Hetzner,
DigitalOcean, etc.) más adelante es **un cambio de destino de despliegue
únicamente** — mismo `docker-compose.yml`, mismo código de `server/`, cero
cambios en la app salvo actualizar la URL por defecto en un release futuro.
Mejora opcional a considerar más adelante (no ahora): que esa URL por
defecto se resuelva contra un endpoint remoto simple en vez de estar
hardcodeada en el binario, para poder migrar el servidor oficial sin
depender de que todos actualicen la app.

**Varios servidores oficiales en el futuro — compatible con el diseño**
Añadir un segundo servidor oficial (otra región, otro proveedor) encajaría
como una implementación adicional detrás de la misma interfaz
`DownloadSource` (por ejemplo, una que intente A y haga fallback a B ante
`quotaExceeded` o servidor inalcanzable) — aditivo sobre lo que ya existe,
no un rediseño. No se propone construirlo ahora; con un servidor oficial
y 5 usuarios no está justificado.

---

## 9. Preguntas abiertas para antes de implementar

1. **Claves por usuario vs. clave única compartida** para el servidor
   oficial: la sección 6 recomienda por-usuario por ser casi el mismo
   costo de implementación y dar mejor trazabilidad/revocación — confirmar
   si se da ese paso ahora o se prefiere la clave única más simple para la
   primera versión.
2. **Umbral exacto del rate limiting** (peticiones por clave por hora,
   tope diario global) — depende del uso real esperado de los 5 usuarios;
   no hay un número "correcto" sin ese dato.
3. **Quién administra la VM de Oracle** (cuenta personal, verificación de
   identidad que Oracle a veces pide para Always Free) — vale la pena
   crear la cuenta y confirmar el alta antes de comprometerse con el plan,
   dado que Oracle es conocido por fricciones de verificación más allá del
   recorte de límites ya mencionado.

---

## 10. Próximos pasos (cuando se decida implementar)

1. Dar de alta la VM Oracle Always Free y validar que el `server/` actual
   corre ahí sin cambios (deploy manual, antes de automatizar nada).
2. Añadir Caddy + DuckDNS al `docker-compose.yml` para TLS gratuito.
3. Implementar rate limiting + (si se confirma en la sección 9) claves por
   usuario en `server/app/`.
4. Añadir `quotaExceeded` a `DownloadSourceErrorKind` y el manejo de
   `Retry-After` en `ytdlp_server_source.dart`/`download_provider.dart`.
5. Cambiar los valores por defecto de `SettingsProvider` y mover la
   sección de servidor a "Ajustes avanzados" en `settings_screen.dart`.
6. Prueba real con los 5 usuarios antes de considerar el modo automático
   terminado.

Orientativo — se planificaría en detalle (archivos, tests, orden de
commits) al momento de avanzar.
