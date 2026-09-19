// Animaciones Lottie enlazadas por URL pública del CDN de LottieFiles. Todas
// están publicadas bajo la Lottie Simple License (uso libre, sin atribución
// obligatoria). Origen, autor y licencia de cada una en README.md.

export const lottie = {
  headphones: {
    src: "https://assets-v2.lottiefiles.com/a/88ce3466-82d7-11ee-8f9f-4f6dd7eae813/PQjunYgF7K.lottie",
    source: "https://lottiefiles.com/free-animation/headphones-wZYnX7cdp7",
    author: "anwar khan",
  },
  listening: {
    src: "https://assets-v2.lottiefiles.com/a/67966846-1189-11ee-97a6-538302e53b46/ojjqk0180b.lottie",
    source: "https://lottiefiles.com/free-animation/listening-to-audio-on-phone-KsaFgoZBMw",
    author: "Danny",
  },
  download: {
    src: "https://assets-v2.lottiefiles.com/a/745b1a9e-117b-11ee-b7e8-e7d1bf622e25/qDnfbYJzBZ.lottie",
    source: "https://lottiefiles.com/free-animation/download-Ch0PxCW02O",
    author: "Mahendra",
  },
} as const;

export type LottieKey = keyof typeof lottie;
