# Heardy

Una aplicación completa de descarga y reproducción de música de YouTube y Spotify que funciona sin conexión.

<img width="300" height="300" alt="image" src="https://github.com/user-attachments/assets/f559d776-36b2-48dc-8954-417d259fa8dd" />


## Características

- Descarga de música de YouTube (videos individuales y playlists)
- **Descarga de música de Spotify**: Soporte completo para tracks, álbumes y playlists de Spotify sin necesidad de API keys
- **Soporte para enlaces cortos**: Compatible con enlaces directos de Spotify y `spotify.link`
- Reproducción de música offline
- **Fondo dinámico en el reproductor**: El fondo del reproductor se adapta de forma visualmente atractiva al color dominante de la carátula de la canción actual.
- **Letras en tiempo real (Sincronizadas)**: Visualización de letras en tiempo real obtenidas de la base de datos colaborativa **LRCLIB**, con scroll automático al ritmo de la reproducción y capacidad de salto temporal al pulsar sobre cualquier línea.
- **Descarga y caché offline de letras**: Las letras se descargan de forma automática junto al audio y se guardan localmente (`.lrc`), garantizando que la visualización de letras funcione 100% offline.
- **Cola de reproducción reordenable ("A continuación")**: Permite gestionar la lista de pistas en cola, reordenar el orden temporalmente mediante gestos táctiles, reproducir pistas con un toque y eliminarlas de la cola mediante deslizamiento.
- Organización en playlists personalizadas
- Búsqueda y filtrado de canciones
- Ordenamiento por artista, título, duración u orden de importación
- Numeración de canciones en playlists
- Control de reproducción en segundo plano
- Notificaciones de progreso de descarga
- Soporte para cooldown entre descargas para evitar bloqueos de YouTube y Spotify

## Tecnologías Utilizadas

### Framework
- **Flutter** - Framework de desarrollo de aplicaciones móviles

### Dependencias Principales

#### Audio y Reproducción
- **[just_audio](https://pub.dev/packages/just_audio)** - Reproductor de audio para Flutter
- **[audio_service](https://pub.dev/packages/audio_service)** - Servicio de audio para reproducción en segundo plano

#### Descarga de Música
- **[youtube_explode_dart](https://pub.dev/packages/youtube_explode_dart)** - Biblioteca para descargar videos de YouTube sin API key
- **Servicio de Spotify personalizado** - Extracción de metadatos de Spotify (tracks, álbumes, playlists) sin API key mediante análisis de páginas embed

#### Base de Datos
- **[sqflite](https://pub.dev/packages/sqflite)** - Base de datos SQLite para Flutter

#### Gestión de Estado
- **[provider](https://pub.dev/packages/provider)** - Gestión de estado simple para Flutter

#### Sistema de Archivos
- **[path_provider](https://pub.dev/packages/path_provider)** - Acceso a directorios del sistema
- **[path](https://pub.dev/packages/path)** - Manipulación de rutas de archivos

#### Permisos
- **[permission_handler](https://pub.dev/packages/permission_handler)** - Gestión de permisos del sistema

#### Utilidades
- **[uuid](https://pub.dev/packages/uuid)** - Generación de identificadores únicos
- **[http](https://pub.dev/packages/http)** - Cliente HTTP
- **[shared_preferences](https://pub.dev/packages/shared_preferences)** - Almacenamiento de preferencias
- **[palette_generator](https://pub.dev/packages/palette_generator)** - Extracción de colores dominantes de imágenes en tiempo real

#### Notificaciones
- **[flutter_local_notifications](https://pub.dev/packages/flutter_local_notifications)** - Notificaciones locales
- **[wakelock_plus](https://pub.dev/packages/wakelock_plus)** - Mantener el dispositivo encendido
- **[flutter_background_service](https://pub.dev/packages/flutter_background_service)** - Servicios en segundo plano

## Créditos

Esta aplicación utiliza las siguientes bibliotecas de código abierto:

- **youtube_explode_dart** por [Hexer10](https://github.com/Hexer10/youtube_explode_dart) - Descarga de videos de YouTube
- **just_audio** por [Ryan Heise](https://github.com/ryanheise/just_audio) - Reproducción de audio
- **audio_service** por [Ryan Heise](https://github.com/ryanheise/audio_service) - Servicio de audio en segundo plano
- **sqflite** por [Flutter Team](https://github.com/flutter/sqflite) - Base de datos SQLite
- **provider** por [Flutter Team](https://github.com/flutter/provider) - Gestión de estado
- **palette_generator** por [Flutter Team](https://github.com/flutter/palette_generator) - Generador de paletas de colores a partir de imágenes

Gracias a todos los desarrolladores de estas bibliotecas por su excelente trabajo.

## Licencia

Este proyecto es de código abierto. Por favor consulta el archivo LICENSE para más detalles.

## Agradecimientos

Gracias a la comunidad de Flutter y a todos los desarrolladores que contribuyen con las bibliotecas de código abierto que hacen posible esta aplicación.
