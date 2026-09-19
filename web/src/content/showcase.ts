// Capturas y vídeos de la sección "Cómo funciona".
//
// Coloca los archivos en `web/public/media/` y rellena `src` con la ruta pública
// (p. ej. "/media/biblioteca-movil.png"). Mientras `src` sea `null` se muestra un
// marcador de posición con la proporción correcta ("captura pendiente").
//
// - `kind: "image"`  → png/jpg/webp.
// - `kind: "video"`  → mp4 o webm; se reproduce en bucle, silenciado y sin controles.
// - `device: "phone"`   → proporción 9:19.5 (móvil).
// - `device: "desktop"` → proporción 16:9 (escritorio).

export type MediaKind = "image" | "video";
export type DeviceFrame = "phone" | "desktop";

export type ShowcaseMedia = {
  kind: MediaKind;
  src: string | null;
  alt: string;
  device: DeviceFrame;
  /** Póster opcional para vídeos (imagen que se ve antes de cargar). */
  poster?: string;
};

export type ShowcaseItem = {
  id: string;
  title: string;
  description: string;
  media: ShowcaseMedia[];
};

export const showcase: ShowcaseItem[] = [
  {
    id: "biblioteca",
    title: "Biblioteca y playlists",
    description:
      "Elige una carpeta de tu dispositivo y Heardy la convierte en tu biblioteca: cada subcarpeta es una playlist, y puedes crear, reordenar y combinar playlists sin mover un solo archivo.",
    media: [
      { kind: "image", src: null, alt: "Biblioteca de playlists en el móvil", device: "phone" },
      { kind: "image", src: null, alt: "Biblioteca en la versión de escritorio", device: "desktop" },
    ],
  },
  {
    id: "reproductor",
    title: "Reproductor y letras",
    description:
      "Controles completos, cola de reproducción, reproducción en segundo plano y letras sincronizadas línea a línea, con traducción opcional al idioma que elijas.",
    media: [
      { kind: "video", src: null, alt: "Letras sincronizadas en el reproductor", device: "phone" },
      { kind: "image", src: null, alt: "Pantalla de reproducción en escritorio", device: "desktop" },
    ],
  },
  {
    id: "estadisticas",
    title: "Estadísticas de escucha",
    description:
      "Tus canciones y artistas más escuchados, rachas y tiempo total. Todo se calcula en tu dispositivo, y puedes compartirlo como imagen cuando quieras.",
    media: [
      { kind: "image", src: null, alt: "Estadísticas de escucha", device: "phone" },
    ],
  },
  {
    id: "bandeja",
    title: "Bandeja de importación",
    description:
      "Los archivos que llegan sueltos a la carpeta aparecen en una bandeja: selecciónalos todos y asígnalos a una o varias playlists en una sola acción.",
    media: [
      { kind: "image", src: null, alt: "Bandeja de importación", device: "phone" },
    ],
  },
  {
    id: "sincronizacion",
    title: "Cuenta opcional y amigos",
    description:
      "Si creas una cuenta, Heardy sincroniza el índice de tu biblioteca y tu historial entre tus dispositivos, y puedes ver qué están escuchando tus amigos. El audio nunca sale de tu dispositivo.",
    media: [
      { kind: "image", src: null, alt: "Pantalla de amigos y escuchando ahora", device: "phone" },
      { kind: "image", src: null, alt: "Estado de sincronización", device: "desktop" },
    ],
  },
];
