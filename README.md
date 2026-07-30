# Heardy

Un reproductor de música para Android, 100% offline, para tu propia biblioteca local. Vos importás tus archivos `.mp3`/`.mp4` desde el explorador de archivos (o los descargás con cualquier otra app) y Heardy los organiza, les lee la metadata y los reproduce — sin backend, sin cuenta, sin conexión a internet.

<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/f559d776-36b2-48dc-8954-417d259fa8dd" />

> Heardy empezó como un descargador de YouTube. Esa capa completa (motor de extracción, circuit breaker anti-bloqueo, integración con YouTube Music y Spotify) se retiró del árbol principal a favor de un reproductor de biblioteca local, pero sigue disponible íntegra en el tag de git `youtube-downloader-final` para quien quiera recuperarla o consultarla.

## Características

- **Biblioteca local vía Storage Access Framework (SAF)**: elegís una carpeta una sola vez; Heardy crea `Heardy/` dentro, con una subcarpeta por playlist. Metés o sacás archivos desde el explorador del sistema, sin pasar por la app.
- **Escaneo incremental**: detecta altas, archivos movidos o renombrados (por hash del audio) y ediciones de tags hechas in situ (por continuidad del archivo), sin perder la metadata ya cacheada ni la organización en playlists.
- **Nada se borra solo**: un archivo que desaparece de la carpeta se marca como faltante, nunca se elimina de la base de datos ni de tus playlists — si vuelve a aparecer, recupera todo tal cual estaba.
- **Bandeja de entrada**: los archivos sueltos sin playlist se listan aparte, con selección múltiple para asignarlos en lote a una o varias playlists (o crear una nueva al vuelo). Los que descartás quedan en una pestaña "Ignoradas", reversible en cualquier momento.
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

## Créditos

Esta aplicación utiliza las siguientes bibliotecas de código abierto:

- **just_audio** por [Ryan Heise](https://github.com/ryanheise/just_audio) — reproducción de audio
- **audio_service** por [Ryan Heise](https://github.com/ryanheise/audio_service) — servicio de audio en segundo plano
- **saf_util** y **saf_stream** por [flutter-cavalry](https://github.com/flutter-cavalry) — acceso a archivos vía Storage Access Framework
- **audio_metadata_reader** por [Clément Beal](https://github.com/ClementBeal/audio_metadata_reader) — lectura de metadata de audio
- **sqflite** por el equipo de Flutter — base de datos SQLite
- **provider** por el equipo de Flutter — gestión de estado
- **palette_generator** por el equipo de Flutter — generador de paletas de colores a partir de imágenes

Gracias a todos los desarrolladores de estas bibliotecas por su excelente trabajo.

## Licencia

Este proyecto es de código abierto. Por favor consulta el archivo LICENSE para más detalles.

## Agradecimientos

Gracias a la comunidad de Flutter y a todos los desarrolladores que contribuyen con las bibliotecas de código abierto que hacen posible esta aplicación.
