// URLs de descarga: cada plataforma tiene su propia Release en GitHub (tags
// `App` y `Ejecutable`). Al publicar una versión nueva, subir los binarios a
// esas releases con los mismos nombres de archivo y actualizar `version` y
// `approxSize` aquí.

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

const releaseBase = "https://github.com/Isaac-Canabal/Heardy/releases/download";

export const downloads: Record<Platform, DownloadTarget> = {
  android: {
    platform: "android",
    label: "Android (APK)",
    fileName: "Heardy.apk",
    url: `${releaseBase}/App/Heardy.apk`,
    version: "1.0.0",
    approxSize: "~ 67 MB",
    requirements: "Android 8.0 o superior. Instalación manual del APK.",
  },
  windows: {
    platform: "windows",
    label: "Windows (instalador)",
    fileName: "Heardy-Setup.exe",
    url: `${releaseBase}/Ejecutable/Heardy-Setup.exe`,
    version: "1.0.0",
    approxSize: "~ 20 MB",
    requirements: "Windows 10 o superior, 64 bits.",
  },
};

// Versión de los términos que el usuario acepta al descargar. Súbela cuando
// cambie el texto de /terminos o /privacidad de forma sustancial: el sitio
// volverá a pedir la aceptación aunque no hayan pasado 30 días.
export const termsVersion = "2026-09-19";
export const termsAcceptanceDays = 30;
