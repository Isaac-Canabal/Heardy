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
      { kind: "image", src: "/media/movil-playlists.jpg", alt: "Lista de playlists con carátula, número de canciones y duración, y el minirreproductor abajo", device: "phone" },
      { kind: "image", src: "/media/escritorio-reproductor.png", alt: "Versión de escritorio: barra lateral, lista de la playlist y panel de reproducción con la letra", device: "desktop" },
    ],
  },
  {
    id: "reproductor",
    title: "Reproductor y letras",
    description:
      "Controles completos, cola de reproducción reordenable, aleatorio, repetición y temporizador de pausa. Letras sincronizadas línea a línea, con traducción opcional debajo de cada verso.",
    media: [
      { kind: "image", src: "/media/movil-reproductor.jpg", alt: "Pantalla de reproducción con la carátula, el título y los controles", device: "phone" },
      { kind: "image", src: "/media/movil-letra.jpg", alt: "Letra sincronizada con la línea actual resaltada", device: "phone" },
      { kind: "image", src: "/media/movil-letra-traducida.jpg", alt: "Letra con la traducción al español debajo de cada línea", device: "phone" },
      { kind: "image", src: "/media/movil-cola.jpg", alt: "Cola de reproducción con las próximas canciones", device: "phone" },
      { kind: "image", src: "/media/movil-opciones.jpg", alt: "Opciones de aleatorio, repetir y temporizador de pausa", device: "phone" },
      { kind: "image", src: "/media/escritorio-reproductor.png", alt: "Panel de reproducción en escritorio con letra sincronizada", device: "desktop" },
    ],
  },
  {
    id: "estadisticas",
    title: "Estadísticas de escucha",
    description:
      "Tus canciones y artistas más escuchados, reproducciones y tiempo total, por semana o por mes. Todo se calcula en tu dispositivo, y puedes compartirlo como imagen cuando quieras.",
    media: [
      { kind: "image", src: "/media/movil-estadisticas.jpg", alt: "Vista previa de la imagen de estadísticas para compartir: reproducciones, tiempo escuchado, top de artistas y canciones", device: "phone" },
    ],
  },
  {
    id: "bandeja",
    title: "Bandeja e importación",
    description:
      "Los archivos que llegan sueltos a la carpeta aparecen en una bandeja: selecciónalos todos y asígnalos a una o varias playlists en una sola acción. Si tienes tu propio servidor, también puedes importar audio desde un enlace, con una cola que avanza sola y se reanuda si se corta.",
    media: [
      { kind: "image", src: "/media/movil-importar.jpg", alt: "Cola de importación con el progreso de la canción actual y las siguientes en espera", device: "phone" },
    ],
  },
  {
    id: "sincronizacion",
    title: "Cuenta opcional y amigos",
    description:
      "Si creas una cuenta, Heardy sincroniza el índice de tu biblioteca y tu historial entre tus dispositivos, y puedes ver qué están escuchando tus amigos. El audio nunca sale de tu dispositivo.",
    media: [
      { kind: "image", src: "/media/movil-cuenta.jpg", alt: "Ajustes de la cuenta: sesión, amigos, sincronización y el interruptor de escuchando ahora", device: "phone" },
    ],
  },
];
