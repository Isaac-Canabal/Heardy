# Heardy

Reproductor de música para tu propia biblioteca, en Android y Windows. La música vive en tu dispositivo: elegís una carpeta, Heardy la organiza en playlists, le lee la metadata y la reproduce sin backend, sin cuenta y sin conexión. Todo lo demás —letras, estadísticas, sincronización entre dispositivos— es opcional y se suma encima sin cambiar eso.

<img width="300" height="300" alt="Heardy" src="https://github.com/user-attachments/assets/f559d776-36b2-48dc-8954-417d259fa8dd" />

## Descargas

- **Android**: APK en la [última release](https://github.com/Isaac-Canabal/Heardy/releases/latest) (`Heardy.apk`). Al instalar fuera de la tienda, Android pide permitir "orígenes desconocidos" para el navegador o el gestor de archivos.
- **Windows**: instalador en la [última release](https://github.com/Isaac-Canabal/Heardy/releases/latest) (`Heardy-Setup.exe`). El instalador no está firmado con certificado, así que SmartScreen avisa de "editor desconocido" la primera vez: *Más información → Ejecutar de todas formas*.

La página del proyecto, con capturas y el detalle de cada función, vive en `web/` (ver más abajo).

## Qué hace

**Biblioteca local**
- Una carpeta, elegida una vez. Heardy crea `Heardy/` dentro, con una subcarpeta por playlist; podés meter o sacar archivos desde el explorador del sistema. En Android se accede por Storage Access Framework, sin permisos de almacenamiento amplios; en Windows, por el sistema de archivos normal.
- Escaneo incremental que reconoce archivos movidos o renombrados (por el hash del audio, no por el nombre) y ediciones de tags hechas por fuera, sin perder la metadata cacheada ni la organización en playlists.
- Nada se borra solo: un archivo que desaparece se marca como faltante y recupera todo si vuelve. Solo se borra de verdad lo que vos pedís borrar — y entonces se borra también el archivo.
- Bandeja de entrada para los archivos sueltos: selección múltiple y asignación en lote a una o varias playlists.
- Metadata real: tags ID3/MP4 con carátula embebida; si faltan, se infieren del nombre del archivo y de la carpeta.

**Reproducción**
- Reproducción en segundo plano con controles en la pantalla de bloqueo (Android) y atajos de teclado (Windows).
- Letras sincronizadas, con traducción línea a línea, cacheadas para verlas sin conexión.
- Cola reordenable, aleatorio, repetición, temporizador de apagado con fundido, fondo dinámico según la carátula.
- Estadísticas de escucha: lo más escuchado por semana y por mes, tiempo total, y una imagen para compartir.

**Escritorio (Windows)**
- Interfaz propia de tres columnas: navegación lateral, contenido, y un panel "Reproduciendo ahora" con letra y cola debajo de la carátula. Barra de reproducción con línea de tiempo y volumen; barra de título integrada con el tema.

**Cuenta opcional**
- Sincroniza entre dispositivos un **índice** de la biblioteca (títulos, artistas, playlists, historial de reproducción), nunca el audio. Sirve para restaurar la biblioteca en otro dispositivo y para las estadísticas.
- Amigos por nombre de usuario y un "escuchando ahora" que se activa explícitamente y caduca solo.
- "Borrar mis datos de la nube" en Ajustes elimina todo lo asociado a la cuenta.

**Importar desde un enlace (opcional)**
- Además de copiar archivos a la carpeta, se puede importar audio pegando un enlace o buscando desde la app. Esa función pasa por un servidor propio (`server/`, FastAPI) que cualquiera puede levantar; el audio importado acaba como un archivo más en tu carpeta, indistinguible de los que copiaste a mano. Ver "Servidor propio".

## Compilar

Requisitos: Flutter estable (canal `stable`), Android SDK para el APK y Visual Studio con la carga de trabajo de C++ para Windows.

```bash
flutter pub get
flutter run                     # Android conectado, o `-d windows`
flutter build apk --release     # APK (firma en android/keystore.properties, fuera del repo)
flutter build windows --release # ejecutable en build/windows/x64/runner/Release/
flutter analyze && flutter test
```

Instalador de Windows: con [Inno Setup 6](https://jrsoftware.org/isinfo.php) instalado, compilar `windows/installer/heardy.iss` (`ISCC.exe windows\installer\heardy.iss`) tras el `flutter build windows --release`; deja `build/windows/installer/Heardy-Setup.exe`.

## Servidor propio

`server/` es un microservicio Python (FastAPI + uvicorn + yt-dlp) que la app consume por HTTP para la función de importar desde un enlace. No es necesario para nada más: sin servidor, la app es un reproductor local completo.

- **Nativo (Windows)**: `server\setup.bat` crea el entorno e instala dependencias; `server\make-key.bat` genera la clave de API que va en *Ajustes → Ajustes avanzados* de la app; `server\run.bat` lo levanta. `server\health.bat` comprueba que responde.
- **Docker**: `cd server && cp .env.example .env` (poner la clave) y `docker compose up -d --build`.
- Todas las opciones están comentadas en `server/.env.example`: claves por persona, límites de uso, cupo diario, cuenta con Firebase, base de datos Postgres para lo que debe sobrevivir a un reinicio, y los ajustes de memoria para instancias pequeñas (512 MB). Tests: `cd server && test.bat`.

Recordá que lo que importás con el servidor es responsabilidad tuya: solo contenido sobre el que tengas derechos.

## Página web (`web/`)

Next.js + shadcn/ui, en la rama `feature/website`. `cd web && npm install && npm run dev` la sirve en `http://localhost:3000`; `npm run build` y `npm run lint` deben quedar limpios.

Todo lo variable está en `web/src/content/`:

- `site.ts` — URL pública (para OpenGraph), repo, nombre del operador y correos de contacto (vienen marcados `PENDIENTE`).
- `downloads.ts` — URLs de descarga (por defecto, la última release de GitHub: `app-release.apk` y `Heardy-Setup.exe`, que hay que adjuntar a la release **con esos nombres exactos**), versión y tamaño aproximado, y `termsVersion`: súbelo cuando cambien los términos y el sitio volverá a pedir la aceptación.
- `showcase.ts` — capturas y vídeos de "Cómo funciona": copia los archivos a `web/public/media/` y sustituye `src: null` por la ruta (`kind: "image"` o `"video"`; `device: "phone"` o `"desktop"` elige el marco). Las dos tarjetas de "Escritorio y móvil" están directamente en `src/app/page.tsx`.

Los textos legales (`src/app/terminos`, `privacidad`, `licencias`) son borradores con aviso visible y notas para el revisor (`<LegalNote>`); al revisarlos, `draft={false}` y fuera las notas. Las animaciones son de LottieFiles por CDN (Lottie Simple License; créditos en `/licencias` y `src/content/lottie.ts`).

Despliegue en Vercel: importar el repo con **Root Directory = `web`**; sin variables de entorno. Tras el primer despliegue, poner el dominio real en `site.ts`.

## Arquitectura

`CLAUDE.md` documenta las decisiones de diseño con detalle: por qué la identidad de una canción es el hash de su audio, por qué la sincronización es aditiva y nunca borra, cómo se reparte la memoria del servidor, y qué alternativas se evaluaron y descartaron.

## Tecnologías

- **Flutter** (Android y Windows) — estado con `provider`, SQLite con `sqflite` (`sqflite_common_ffi` en escritorio).
- Audio: `just_audio` + `audio_service` + `audio_session`; en Windows, `just_audio_media_kit` (libmpv).
- Biblioteca: `saf_util` / `saf_stream` (Android), `file_picker` (escritorio), `audio_metadata_reader`, `crypto`.
- Escritorio: `window_manager` (barra de título propia), Inno Setup (instalador).
- Cuenta y sincronización: Firebase Auth (SDK en Android, API REST en escritorio), servidor FastAPI con Postgres.
- Letras: [LRCLIB](https://lrclib.net/).
- Servidor: FastAPI, uvicorn, yt-dlp, bgutil-ytdlp-pot-provider, asyncpg, PyJWT.
- Web: Next.js, shadcn/ui, Tailwind, LottieFiles.

## Créditos

Gracias a los autores y mantenedores de `just_audio` y `audio_service` (Ryan Heise), `saf_util`/`saf_stream` (flutter-cavalry), `audio_metadata_reader` (Clément Beal), `media_kit`, `window_manager`, `sqflite`, `provider`, `palette_generator`, FastAPI (Sebastián Ramírez), yt-dlp y bgutil-ytdlp-pot-provider, LRCLIB, y a la comunidad de Flutter.

## Licencia

MIT — ver `LICENSE`.
