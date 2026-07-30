# Investigación: fallos intermitentes de descarga (403 / VideoUnavailableException / VideoUnplayableException)

Sesión del 2026-07-28. Handoff para continuar en la próxima sesión — no hay
conclusión cerrada, hay un solo experimento pendiente y bien acotado.

## Estado de las hipótesis

1. **"YouTube endureció su detección" — eliminada por sustitución.** Se probó
   el código de `main` (el que Isaac confirma que bajó 100+ canciones seguidas)
   en tres IPs distintas a lo largo de la sesión, y en las tres terminó
   chocando con el mismo muro (`VideoUnplayableException`, "Sign in to confirm
   you're not a bot") una vez agotado el presupuesto de esa IP. Si `main`
   fallara igual que el branch actual en igualdad de condiciones de IP, el
   endurecimiento de YouTube sería la explicación suficiente. No fue así en el
   único punto de comparación limpio que se consiguió (ver baseline abajo):
   `main` completó 15/15 con una IP descansada. La sospecha de "endurecimiento"
   no está descartada como factor de fondo (el muro existe y es real), pero
   **no explica por sí sola** por qué el branch actual falla donde `main` no.

2. **Amplificación de peticiones de manifest — real, medida, pero insuficiente
   como única causa raíz.** Antes de los fixes de esta sesión, una canción
   fallida en el branch actual podía emitir 50-60 peticiones de manifest
   (2 intentos externos × 5 internos × 4-6 de cascada de clientes) contra un
   presupuesto de IP medido en ~12-24. Los fixes aplicados (ver
   `git log --oneline` de hoy) lo bajaron a 1 petición en el camino del muro
   detectado como tal. Sigue siendo cierto y vale la pena, pero el hallazgo de
   esta sesión es que **hay un modo de fallo separado** que la amplificación no
   explica (ver "tres modos de fallo" abajo).

3. **UA de bytes (commit `22ab25d`) — sin resolver, bloqueado por falta de IP
   limpia.** Hipótesis: `_streamUserAgent` (UA de Android) no coincide con lo
   que usa `main` (UA de Pixel 5 / Chrome 120) para descargar bytes, y esa
   diferencia podría ser la causa del 403-en-bytes con manifest sano observado
   una vez. Se intentó aislarlo con Test A (revertir sólo el UA) tres veces —
   IP de escritorio, IP de escritorio tras esperar, hotspot móvil — y las tres
   veces el experimento no llegó a producir un dato limpio porque la IP estaba
   bloqueada *antes* de llegar a bytes (ver tercer modo de fallo). **Sigue
   siendo la hipótesis más viva para el 403-en-bytes específicamente**, porque
   es la única vez que se observó ese modo de fallo particular, y coincidió con
   la única corrida donde se tocó `_streamUserAgent`. Pero con n=1 y sin
   réplica limpia, no está confirmada.

## Baseline de `main` (2026-07-28, ~15:27)

Corrida de 15 canciones, IP de escritorio recién confirmada sana con canario
de 2 manifests:

- **15/15 completadas.**
- **15 peticiones de manifest totales** (1 por canción; el fallback interno de
  la librería a `tv` nunca se activó).
- **141 s** de tiempo total (incluye descarga completa de audio, no sólo
  manifest).
- Mezcla de música popular (Taylor Swift, Bad Bunny, Sabrina Carpenter) y
  nicho (bedroom demos, tutoriales), ningún vídeo repetido de pruebas previas.

Este es el número contra el que comparar cualquier corrida futura del branch
actual — pero **sólo es válida la comparación si la IP de la corrida del
branch actual pasó el mismo canario justo antes.**

## Los tres modos de fallo distintos observados, y el estado de IP en cada uno

| # | Síntoma | Dónde ocurre | Estado de IP al momento |
|---|---|---|---|
| 1 | `VideoUnplayableException` / `VideoUnavailableException`, "Sign in to confirm you're not a bot" | Manifest (`_getManifestWithFallback`) | IP con presupuesto agotado por volumen acumulado de la propia sesión — el modo "clásico" medido y explicado por la hipótesis de amplificación. Reproducido muchas veces, en distintas IPs, siempre después de suficiente actividad previa. |
| 2 | `HttpException: HTTP 403 al descargar el stream` | Descarga de bytes (`_downloadViaParallelChunks`), **con manifest sano** (3/3 intentos exitosos por canción) | Ocurrió UNA vez, en 15/15 canciones, inmediatamente después de un canario que había pasado 2/2. Es decir: la IP estaba sana para manifest en ese momento exacto, y aun así bytes falló siempre. No se ha podido reproducir ni descartar desde entonces porque las corridas posteriores volvieron a caer en el modo 1 antes de llegar a bytes. |
| 3 | `VideoUnplayableException` en manifest, en una IP **nunca antes usada en la sesión** (hotspot móvil) | Manifest | La IP nueva falló de entrada. Conectividad básica a youtube.com confirmada OK (200, ~2.6s) — no es un problema de red/entorno. Lectura más probable: CGNAT — los operadores móviles comparten una misma IP pública entre miles de usuarios, así que "nueva para nosotros" no es lo mismo que "limpia para YouTube". |

**La pregunta abierta es si el modo 2 (403-en-bytes con manifest sano) es un
estado de IP más "leve" que el modo 1 (un umbral intermedio: bastante
bloqueada para bytes, no tanto para manifest), o si de verdad es el commit
`22ab25d` del UA. Ambas explicaciones son compatibles con los datos actuales.**

## Qué queda pendiente — un solo experimento, bien acotado

Con **IP residencial descansada** (no de escritorio recién usada, no hotspot
móvil/CGNAT):

1. Canario de 2 manifests (`ytClients: [YoutubeApiClient.android]`,
   `requireWatchPage: false`). Si falla, esperar más — la ventana de
   recuperación medida esta sesión fue de 20-40+ min, no un número fijo.
2. Si el canario pasa 2/2: correr **Test A**, `test/ua_test2.dart` (ya en el
   repo, IDs sin usar en esta sesión). El UA de bytes ya está puesto en el
   valor de `main` (ver el marcador `EXPERIMENTO EN CURSO` en
   `youtube_service.dart` junto a `_streamUserAgent`) — no hace falta editar
   nada, sólo correr el test.
   - **Si completa 2/2 con audio real:** el 403-en-bytes de la sesión anterior
     fue un estado de IP, no el UA — revertir `_streamUserAgent` al valor
     original (`com.google.android.youtube/20.10.38 ...`, está documentado en
     el comentario de al lado) y cerrar la hipótesis 3. Rehacer entonces la
     comparación branch-actual-vs-`main` completa (15 canciones cada uno, IP
     fresca compartida) para tener el número real de la reducción lograda.
   - **Si falla igual, con manifest sano:** la hipótesis del UA sigue viva —
     correr Test B (manifest con `[YoutubeApiClient.androidVr,
     YoutubeApiClient.safari]`, igual que `main` exactamente, con el mismo UA
     de bytes) antes de descartarla o promoverla a fix.

No hay nada más pendiente de esta investigación fuera de este experimento.

## Cambios aplicados esta sesión que NO dependen de IP (ya en el repo)

- Circuit breaker: techo de escalada 180s → 20 min (`_recordBlock`), acorde a
  la ventana de recuperación real medida.
- `YTMusicService.searchAndDownload()`: ahora intenta InnerTube (`searchSongs`)
  primero, con fallback a `YoutubeService.searchAndDownload()` (que sigue
  usando `yt.search.search()`, con su bug de librería) sólo si InnerTube falla
  o no tiene resultados. Antes no había ningún fallback: toda descarga de
  Spotify dependía en exclusiva de la búsqueda rota.
- `_isRetryableError` reconoce `NoSuchMethodError` como transitorio (el bug de
  `search()` es intermitente por vídeo, no permanente).

## Sesión 2026-07-29 — Test A/B resueltos, hipótesis 3 cerrada (parcialmente distinta de lo esperado)

Canario de 2 manifests previo: 2/2 (IDs `09R8_2nJtjg`, `kXYiU_JCYtU`, sin usar
antes en la investigación). IP confirmada sana antes de tocar la red.

**Test A** (`test/ua_test2.dart`, UA de bytes = main): manifest sano en las 2
canciones, pero **403 en bytes 2/2**. El UA por sí solo NO resuelve el
403-en-bytes — hipótesis 3 tal como estaba redactada (desajuste UA↔cliente)
queda descartada.

**Test B** (`tool/testb_probe.dart`, mismos 2 vídeos de Test A, mismo UA,
único cambio: manifest con `[androidVr, safari]` en vez de la cascada
`android`/`androidSdkless`): **HTTP 206 completo, 2/2**. Variable aislada
correctamente — la causa real del 403-en-bytes es el CLIENTE que resolvió el
manifest, no el UA de bytes en sí.

**Cambios promovidos a fix real** (`lib/services/youtube_service.dart`):
- `_clientFallbacks` ahora prueba `[androidVr, safari]` primero. `android` /
  `androidSdkless` / `[android, androidSdkless]` quedan como último recurso —
  no se eliminan porque no está medido que `androidVr`/`safari` cubran el 100%
  de los vídeos.
- `downloadVideoWithAudio` ahora rastrea qué cliente resolvió el manifest
  (`usedClientIndex`) y, si la descarga de bytes da 403 (marcador
  `streamHttpErrorMarker`), el siguiente intento escala al SIGUIENTE cliente de
  la cascada (`manifestStartIndex`) en vez de volver a pedir un manifest con el
  mismo cliente determinista — eso último sólo repetía el mismo 403 gastando
  presupuesto de IP.
- `test/ua_test2.dart` eliminado (cumplió su propósito; el UA no era la causa).
  `tool/canary_probe.dart` y `tool/testb_probe.dart` quedan en el repo como los
  demás probes de esta investigación.

**Modo 1 vs modo 2, revisado:** no se encontró evidencia de que instancias
pasadas de "modo 1" (muro en manifest, `VideoUnplayableException` /
`VideoUnavailableException` con "confirm you're not a bot") fueran en realidad
modo 2 mal diagnosticado. `tool/client_sweep_probe.dart` ya había medido que,
con la sesión bloqueada, los 11 clientes de InnerTube fallan a la vez en el
paso de MANIFEST — incluyendo `androidVr` y `safari`. Eso es consistente con
que el modo 1 es un bloqueo de sesión/IP genuino, no un artefacto de qué
cliente probó primero la cascada vieja. La confusión cliente-dependiente
aplica sólo al modo 2 (bytes), que ocurre con el manifest ya resuelto — son
mecanismos distintos y las cadenas de error no se solapan
(`_isHardBlockError`/`isBotWallError` exigen el texto "confirm you're not a
bot"; `streamHttpErrorMarker` sólo matchea errores del paso de bytes).

**Pendiente, bloqueado por canario:** se intentó correr la comparación de 15
canciones (branch actual vs. baseline de `main` de 141s/15 manifests) con
vídeos nuevos resueltos por búsqueda InnerTube (evita IDs inventados que
podrían no existir y disparar `_isHardBlockError` por una razón real, no el
muro). El canario previo a esa corrida dio **1/2** (`09R8_2nJtjg` volvió a
fallar con el muro clásico; `kXYiU_JCYtU` pasó) — IP en estado mixto/degradado
tras las corridas de Test A/B de esta misma sesión. Por protocolo, no se
procedió con la comparación de 15 con una IP en ese estado. IDs ya resueltos y
listos para la próxima sesión (verificar que siguen vigentes si pasa mucho
tiempo):

```
Kx7B-XvmFtE  Imagine Dragons — Believer
J7p4bzqLvCw  The Weeknd — Blinding Lights
ZD6rXLXZOEI  Billie Eilish — bad guy
OsfAnsMY21M  Dua Lipa — Levitating
4EQkYVtE-28  Post Malone — Circles
9qnqYL0eNNI  Coldplay — Yellow
4wOLVrGHiIU  Eminem — Lose Yourself
4mVo93E9wpU  Rihanna — Diamonds
M51-spaR4qk  Katy Perry — Firework
lNilb-EaTOU  Maroon 5 — Memories
uzaYLK3k0DQ  Sia — Chandelier
2NiyrtYegso  Avicii — Wake Me Up
1FeEa2Ew2yo  Shakira — Waka Waka
pIWaVJPl0-c  Alan Walker — Faded
6xzN8Nt0Pok  Whitney Houston — I Wanna Dance With Somebody
b72gdhV_rXM  Queen — Another One Bites the Dust (canario de repuesto)
Kr4EQDVETuA  Michael Jackson — Billie Jean (canario de repuesto)
```

### El sondeo periódico mantenía la ventana abierta — y una corrida larga la vuelve a cerrar

Mismo día, más tarde: un sondeo de recuperación (`tool/recovery_probe.dart`,
canario de 2 manifests cada 5 min con IDs distintos) dio **0/2 sostenido
durante 25+ minutos seguidos**. Se paró el sondeo por completo (mató el
proceso `dart` — `TaskStop` reportó éxito pero el proceso seguía vivo),
se esperó en silencio real, y un **único** canario post-silencio
(`tool/silence_canary_check.dart`, IDs `b72gdhV_rXM`/`Kr4EQDVETuA`, los "de
repuesto" de la lista de arriba) dio **2/2 tras sólo ~10-12 min** de silencio
— no los 20-40 min que se venía estimando. Conclusión: el propio sondeo
periódico era lo que mantenía el bloqueo, no una recuperación lenta de fondo.

Pero el 2/2 no se sostuvo: la comparación de 15 canciones que arrancó
inmediatamente después (`test/fifteen_song_comparison_test.dart`) volvió a
chocar con el muro clásico (`VideoUnplayableException`, "confirm you're not a
bot") alrededor de la canción 6, con el circuit breaker escalando 4 bloqueos
consecutivos (160s→320s→640s) dentro de la misma corrida, y el test entero
cortado a los 15 min habiendo llegado a menos de 10 de las 15 canciones. Los
datos de las canciones 1-5 se perdieron porque el comando de fondo usó
`| tail -50`, que truncó la salida temprana antes de guardarla — **no volver a
canalizar la salida de una corrida larga por `tail` cuando corre en
background; dejar que el archivo de salida completo se capture solo.**

Lectura: un canario de 2 manifests y una descarga real (metadata + manifest +
varios chunks de bytes en paralelo, por canción) gastan presupuesto de IP a
ritmos muy distintos. Que el canario pase sólo dice "la IP no está bloqueada
ahora mismo", no "hay presupuesto para sostener una sesión larga". La
comparación de 15 canciones contra el baseline de `main` sigue **sin
resolverse** — pendiente para una próxima ventana de silencio, con la salida
completa capturada sin truncar.

### Protocolo rediseñado: 5 vs 5, no 15 vs 15

15 canciones no entra en una ventana de ~10-12 min. Nuevo protocolo: silencio
total → un solo canario → si pasa, 5 canciones en el branch actual y 5 en
`main` en la misma ventana, alternando cuál corre primero entre corridas
sucesivas (el que va segundo carga con lo que quede de presupuesto). Métrica
principal: **manifests emitidos por canción**, no cuántas completan — si el
branch emite más manifests por canción que `main`, esa es la causa raíz
confirmada.

Harness ya preparado (2026-07-29), sin tocar red para construirlo:
- **Grupo A** (branch, este repo): `test/five_song_comparison_branch_test.dart`
  — `SzJXikN_4wA`, `UdGMRQg5szM`, `DntZ3-yCaFs`, `QQXZyf0OJpI`, `TRjlrJ2zqn0`.
- **Grupo B** (`main`, worktree `C:/heardy-main`):
  `test/five_song_comparison_main_test.dart` — `Ns0svgOVo10`, `7P_QfAm1JAA`,
  `TiebZllW8As`, `62yox0F5lcA`, `nJCPPtdfkU8`.
- **Reserva para la próxima corrida** (alternar orden): `rt_z10mb_k0`,
  `T6Cfm27rHwA`, `zFQZpROy6nQ`, `RV2eDTNjENI`, `GwbSJFtRmDw`.

Los 15 IDs son los del baseline de `main` del 2026-07-28 (`main_15_test.dart`,
15/15, 15 manifests, 141s), partidos en tres grupos de 5 — evita resolver IDs
nuevos por búsqueda InnerTube durante la ventana de silencio (eso también
sería tráfico).

Ambos harnesses escriben TODO el output a un archivo desde dentro del proceso
Dart (zona con `print` interceptado, ver `_logPath` en cada test) — no
dependen de que el proceso externo capture stdout sin truncar, así que un
corte a mitad de la corrida no pierde los datos de las canciones que sí
completaron (el problema de la corrida anterior). Cuentan manifests por
canción parseando líneas `"Manifest intento #"` — se agregó ese print
(incondicional, éxito y fallo) a `_getManifestWithFallback` en el branch, y una
instrumentación temporal equivalente al `youtube_service.dart` del worktree de
`main` (marcada "no commitear" en el propio archivo). `main` no tiene circuit
breaker ni `BotWallException` — esas dos métricas quedan en 0/N-A ahí por
diseño.

**Esta corrida (la próxima vez que haya ventana): branch primero, main
segundo.** La siguiente corrida después de esa debería invertir el orden.

## Bug de librería confirmado, sin relación con el muro anti-bot

`yt.search.search()` de `youtube_explode_dart` 3.1.0 falla ~2/3 de las veces
con `NoSuchMethodError: Class '_Map<String, dynamic>' has no instance method
'getT'`, reproducido con IP sana. Es un bug real del parser de
`search_page.dart:181` (falla al leer `viewCountText` en formato "runs" en vez
de "simpleText"), no algo causado por este proyecto. Cubierto por el fallback y
el reconocimiento en `_isRetryableError` de arriba.
