# Heardy

Un reproductor de música para Android, 100% offline, para tu propia biblioteca local. Vos importás tus archivos `.mp3`/`.mp4` desde el explorador de archivos (o los descargás con cualquier otra app) y Heardy los organiza, les lee la metadata y los reproduce — sin backend, sin cuenta, sin conexión a internet.

<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/f559d776-36b2-48dc-8954-417d259fa8dd" />

> Heardy empezó como un descargador de YouTube. Esa capa completa (motor de extracción, circuit breaker anti-bloqueo, integración con YouTube Music y Spotify) se retiró del árbol principal a favor de un reproductor de biblioteca local, pero sigue disponible íntegra en el tag de git `youtube-downloader-final` para quien quiera recuperarla o consultarla.
>
> La rama `feature/youtube-downloads` la reintroduce, pero como una segunda forma de incorporar canciones a esta misma biblioteca — no como un sistema aparte: descargar un video, una playlist o un enlace de Spotify termina siendo un archivo más en tu carpeta `Heardy/`, indistinguible de uno que copiaste a mano. La extracción vive en un microservicio propio (`server/`, FastAPI + yt-dlp), y la app funciona en **modo automático** contra un servidor oficial por defecto — instalás y descargás ya, sin configurar nada. Quien prefiera su propio servidor (más privado, sin depender de que el oficial esté encendido) lo levanta con `server/README.md` y lo apunta desde Ajustes → Ajustes avanzados; ver `CLAUDE.md` para el detalle completo de arquitectura.

## Características

- **Biblioteca local vía Storage Access Framework (SAF)**: elegís una carpeta una sola vez; Heardy crea `Heardy/` dentro, con una subcarpeta por playlist. Metés o sacás archivos desde el explorador del sistema, sin pasar por la app.
- **Escaneo incremental**: detecta altas, archivos movidos o renombrados (por hash del audio) y ediciones de tags hechas in situ (por continuidad del archivo), sin perder la metadata ya cacheada ni la organización en playlists.
- **Nada se borra solo**: un archivo que desaparece de la carpeta se marca como faltante, nunca se elimina de la base de datos ni de tus playlists — si vuelve a aparecer, recupera todo tal cual estaba. Cuando **vos** pedís eliminar una canción o una playlist, en cambio, sí se borra de verdad — de la base y del archivo real en tu carpeta — y el espacio usado que ves en Ajustes refleja el tamaño real de la carpeta, no solo lo que quedó en el almacenamiento privado de la app.
- **Bandeja de entrada**: los archivos sueltos sin playlist se listan aparte, con selección múltiple para asignarlos en lote a una o varias playlists (o crear una nueva al vuelo). Los que descartás quedan en una pestaña "Ignoradas", reversible en cualquier momento.
- **Importar por URL o por búsqueda**: pegás un enlace de un video o playlist de YouTube (o de Spotify — la app busca el mejor equivalente en YouTube por duración, nunca a ciegas) y ves una vista previa antes de decidir a qué playlist va; o buscás directamente dentro de la app con el mismo buscador que usás para tu biblioteca local. Todo pasa por la misma cola de descargas, con progreso y reintento automático.
- **Lista de espera cuando el servidor no responde**: si el servidor de descargas está apagado justo cuando pedís algo, la URL se guarda en vez de perderse, y se resuelve sola en cuanto el servidor vuelve a estar disponible — sin que tengas que volver a pegarla.
- **Reintentos honestos, sin cifras inventadas**: si el límite propio del servidor se agota o YouTube bloquea temporalmente las descargas, la app espera y reintenta sola con el tiempo real (o el rango medido, cuando no hay un número exacto que dar) — nunca descarta una canción perfectamente descargable por apurarse a reintentar.
- **Metadata real**: lee tags ID3v1/ID3v2 y atómos MP4/M4A, incluida la carátula embebida. Si un archivo no tiene tags, infiere título y artista del nombre de archivo (limpiando numeración y ruido tipo `[Official Video]`), y usa el nombre de la carpeta como álbum.
- **Reproducción en segundo plano y controles de pantalla bloqueada**, vía `audio_service` — notificación con carátula, play/pausa/siguiente desde el bloqueo del teléfono.
- **Fondo dinámico**: el color de fondo del reproductor se adapta a la carátula de la canción actual.
- **Letras sincronizadas**: se buscan en la base colaborativa **LRCLIB** la primera vez que reproducís una canción y quedan cacheadas localmente (`.lrc`) para verlas offline después, con scroll automático y salto al tocar una línea.
- **Cola reordenable ("A continuación")**: reordenar por gesto, reproducir con un toque, sacar de la cola deslizando.
- **Búsqueda local instantánea** por título o artista, sin red.
- **Playlists personalizadas**: crear, renombrar, reordenar, ordenar sus canciones por artista/título/duración/orden de importación.
- **Temporizador de apagado** con fundido de volumen antes de pausar.
- **Estadísticas de escucha**: canciones y artista más escuchados, tiempo total, por semana y por mes.

## Tecnologías utilizadas

### Framework
- **Flutter**

### Audio y reproducción
- **[just_audio](https://pub.dev/packages/just_audio)** — decodificación y reproducción de audio
- **[audio_service](https://pub.dev/packages/audio_service)** — reproducción en segundo plano, notificación y controles de pantalla bloqueada
- **[audio_session](https://pub.dev/packages/audio_session)** — gestión del foco de audio del sistema

### Acceso a la biblioteca local
- **[saf_util](https://github.com/flutter-cavalry/saf_util)** — selección de carpeta y listado de archivos vía Storage Access Framework, sin permisos de almacenamiento amplios
- **[saf_stream](https://github.com/flutter-cavalry/saf_stream)** — lectura de contenido de archivos SAF por rango de bytes
- **[audio_metadata_reader](https://github.com/ClementBeal/audio_metadata_reader)** — lectura de tags ID3/MP4 y carátulas embebidas
- **[crypto](https://pub.dev/packages/crypto)** — hash del contenido de audio, para identificar una canción aunque se mueva o le editen los tags

### Base de datos
- **[sqflite](https://pub.dev/packages/sqflite)** — SQLite para Flutter

### Gestión de estado
- **[provider](https://pub.dev/packages/provider)**

### Sistema de archivos
- **[path_provider](https://pub.dev/packages/path_provider)** — directorios privados de la app (carátulas, letras cacheadas)
- **[path](https://pub.dev/packages/path)** — manipulación de rutas

### Permisos
- **[permission_handler](https://pub.dev/packages/permission_handler)**

### Utilidades
- **[uuid](https://pub.dev/packages/uuid)** — identificadores únicos
- **[http](https://pub.dev/packages/http)** — consultas a LRCLIB para las letras
- **[shared_preferences](https://pub.dev/packages/shared_preferences)** — preferencias y estado de reproducción
- **[palette_generator](https://pub.dev/packages/palette_generator)** — color dominante de la carátula para el fondo dinámico

### Notificaciones
- **[flutter_local_notifications](https://pub.dev/packages/flutter_local_notifications)**

### Servidor de descargas (`server/`, rama `feature/youtube-downloads`)

No es una dependencia de Flutter — es un microservicio propio que la app consume por HTTP, para que toda la fragilidad frente a YouTube se resuelva actualizando una pieza del servidor, no publicando una release de la app.

- **[FastAPI](https://fastapi.tiangolo.com/)** + **uvicorn** — la API HTTP (`/resolve`, `/playlist`, `/search`, `/audio`)
- **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** — el motor de extracción, deliberadamente sin fijar versión: es la pieza que más vale tener siempre actualizada
- **[bgutil-ytdlp-pot-provider](https://github.com/Brainicism/bgutil-ytdlp-pot-provider)** — genera los PO Tokens que YouTube exige desde 2025; sin esto, la mayoría de descargas fallan con 403
- **[Tailscale](https://tailscale.com/)** — cómo se publica el servidor oficial a internet (Funnel, HTTPS automático) sin abrir puertos en el router; también la forma recomendada de llegar a un servidor personal desde fuera de casa
- Docker (opcional) — para dejar el servidor corriendo permanentemente sin depender de una terminal abierta; no hace falta para desarrollar ni para uso personal ocasional

## Créditos

Esta aplicación utiliza las siguientes bibliotecas de código abierto:

- **just_audio** por [Ryan Heise](https://github.com/ryanheise/just_audio) — reproducción de audio
- **audio_service** por [Ryan Heise](https://github.com/ryanheise/audio_service) — servicio de audio en segundo plano
- **saf_util** y **saf_stream** por [flutter-cavalry](https://github.com/flutter-cavalry) — acceso a archivos vía Storage Access Framework
- **audio_metadata_reader** por [Clément Beal](https://github.com/ClementBeal/audio_metadata_reader) — lectura de metadata de audio
- **sqflite** por el equipo de Flutter — base de datos SQLite
- **provider** por el equipo de Flutter — gestión de estado
- **palette_generator** por el equipo de Flutter — generador de paletas de colores a partir de imágenes
- **yt-dlp** por sus [mantenedores y contribuidores](https://github.com/yt-dlp/yt-dlp) — el motor de extracción detrás de `server/`
- **bgutil-ytdlp-pot-provider** por [Brainicism](https://github.com/Brainicism/bgutil-ytdlp-pot-provider) — generación de PO Tokens
- **FastAPI** por [Sebastián Ramírez](https://github.com/tiangolo/fastapi) — el framework del servidor de descargas
- **Tailscale** — la red que hace posible tanto el servidor oficial como uno personal sin exponer nada directamente a internet

Gracias a todos los desarrolladores de estas bibliotecas por su excelente trabajo.

## Licencia

Este proyecto es de código abierto. Por favor consulta el archivo LICENSE para más detalles.

## Agradecimientos

Gracias a la comunidad de Flutter y a todos los desarrolladores que contribuyen con las bibliotecas de código abierto que hacen posible esta aplicación.
