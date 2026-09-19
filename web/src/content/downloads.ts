// URLs de descarga. Apuntan al último GitHub Release del repositorio: para que
// funcionen hay que publicar una Release con dos assets cuyos nombres sean
// exactamente `app-release.apk` y `Heardy-Setup.exe` (ver README.md, sección
// "Descargas"). Versión y tamaño son informativos: actualizarlos a mano en cada
// publicación.

export type Platform = "android" | "windows";

export type DownloadTarget = {
  platform: Platform;
  label: string;
  fileName: string;
  url: string;
  version: string;
  approxSize: string;
  requirements: string;
};

const releaseBase =
  "https://github.com/Isaac-Canabal/Heardy/releases/latest/download";

export const downloads: Record<Platform, DownloadTarget> = {
  android: {
    platform: "android",
    label: "Android (APK)",
    fileName: "app-release.apk",
    url: `${releaseBase}/app-release.apk`,
    version: "PENDIENTE (p. ej. 1.0.0)",
    approxSize: "~ 60 MB",
    requirements: "Android 8.0 o superior. Instalación manual del APK.",
  },
  windows: {
    platform: "windows",
    label: "Windows (instalador)",
    fileName: "Heardy-Setup.exe",
    url: `${releaseBase}/Heardy-Setup.exe`,
    version: "PENDIENTE (p. ej. 1.0.0)",
    approxSize: "~ 80 MB",
    requirements: "Windows 10 o superior, 64 bits.",
  },
};

// Versión de los términos que el usuario acepta al descargar. Súbela cuando
// cambie el texto de /terminos o /privacidad de forma sustancial: el sitio
// volverá a pedir la aceptación aunque no hayan pasado 30 días.
export const termsVersion = "2026-09-19";
export const termsAcceptanceDays = 30;
