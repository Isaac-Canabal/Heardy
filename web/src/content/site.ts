// Datos generales del sitio. Todo lo que sea un marcador de posición está
// señalado con "PENDIENTE" para que se rellene antes de publicar.

export const site = {
  name: "Heardy",
  tagline: "Tu música, en tu dispositivo.",
  description:
    "Heardy es un reproductor de música local para Android y Windows: biblioteca por carpetas y playlists, letras sincronizadas y traducidas, estadísticas de escucha y sincronización opcional entre dispositivos.",
  // PENDIENTE: dominio real donde se publicará el sitio (se usa en metadatos OpenGraph).
  url: "https://heardy.example.com",
  repoUrl: "https://github.com/Isaac-Canabal/Heardy",
  licenseUrl: "https://github.com/Isaac-Canabal/Heardy/blob/main/LICENSE",
  // Un solo buzón para contacto, reclamaciones de derechos y datos personales.
  contactEmail: "vainastech@gmail.com",
  legalEmail: "vainastech@gmail.com",
  privacyEmail: "vainastech@gmail.com",
  // Quien responde de la app y del tratamiento de datos. Si más adelante hay
  // una razón social, va aquí.
  operatorName: "Vainastech",
  operatorLocation: "Colombia",
  // Fecha de la última revisión de los textos legales.
  legalUpdatedAt: "2026-09-19",
} as const;
