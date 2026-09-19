import type { Metadata } from "next";

import { LegalPage, LegalSection } from "@/components/legal-page";
import { lottie } from "@/content/lottie";
import { site } from "@/content/site";

export const metadata: Metadata = {
  title: "Licencias y créditos",
  description: "Licencia MIT de Heardy y créditos de las bibliotecas y servicios de terceros que utiliza.",
};

const mitText = `MIT License

Copyright (c) 2026 Isaac Canabal

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.`;

const thirdParty = [
  {
    name: "Flutter y Dart",
    license: "BSD-3-Clause",
    url: "https://flutter.dev",
    note: "Framework con el que está construida la aplicación para Android y Windows.",
  },
  {
    name: "just_audio, audio_service y audio_session",
    license: "MIT",
    url: "https://pub.dev/packages/just_audio",
    note: "Reproducción de audio, cola y controles del sistema.",
  },
  {
    name: "media_kit / libmpv",
    license: "MIT (media_kit) · LGPL-2.1+ (libmpv)",
    url: "https://github.com/media-kit/media-kit",
    note: "Motor de reproducción en la versión de Windows. libmpv se enlaza dinámicamente conforme a la LGPL.",
  },
  {
    name: "yt-dlp",
    license: "Unlicense (dominio público)",
    url: "https://github.com/yt-dlp/yt-dlp",
    note: "Extracción de audio desde enlaces, en el servidor opcional.",
  },
  {
    name: "FastAPI",
    license: "MIT",
    url: "https://fastapi.tiangolo.com",
    note: "Framework del servidor opcional.",
  },
  {
    name: "LRCLIB",
    license: "Servicio público; letras aportadas por la comunidad",
    url: "https://lrclib.net",
    note: "Fuente de las letras sincronizadas. Se consulta enviando título, artista y duración de la canción.",
  },
  {
    name: "MyMemory",
    license: "Servicio de terceros con sus propias condiciones",
    url: "https://mymemory.translated.net",
    note: "Traducción de letras línea a línea.",
  },
  {
    name: "Firebase Authentication",
    license: "Condiciones de servicio de Google",
    url: "https://firebase.google.com/terms",
    note: "Identidad de la cuenta opcional.",
  },
  {
    name: "sqflite, provider, shared_preferences, http y demás paquetes de pub.dev",
    license: "BSD / MIT según paquete",
    url: "https://github.com/Isaac-Canabal/Heardy/blob/main/pubspec.yaml",
    note: "La lista completa y sus licencias están en el pubspec.yaml del repositorio.",
  },
];

const webDeps = [
  { name: "Next.js y React", license: "MIT", url: "https://nextjs.org" },
  { name: "Tailwind CSS", license: "MIT", url: "https://tailwindcss.com" },
  { name: "shadcn/ui y Base UI", license: "MIT", url: "https://ui.shadcn.com" },
  { name: "Lucide", license: "ISC", url: "https://lucide.dev" },
  { name: "@lottiefiles/dotlottie-react", license: "MIT", url: "https://github.com/LottieFiles/dotlottie-web" },
];

export default function LicensesPage() {
  return (
    <LegalPage
      title="Licencias y créditos"
      intro="Heardy es software libre. Aquí está su licencia y el reconocimiento a los proyectos y servicios de terceros de los que depende."
    >
      <LegalSection id="mit" title="Licencia de Heardy (MIT)">
        <p>
          El código fuente de la aplicación, del servidor opcional y de este sitio web se publica en{" "}
          <a href={site.repoUrl} target="_blank" rel="noopener noreferrer">
            GitHub
          </a>{" "}
          bajo la licencia MIT:
        </p>
        <pre className="overflow-x-auto rounded-xl border border-border/60 bg-black/30 p-4 font-mono text-xs leading-relaxed whitespace-pre-wrap text-foreground/80">
          {mitText}
        </pre>
      </LegalSection>

      <LegalSection id="terceros" title="Bibliotecas y servicios de terceros (aplicación)">
        <ul>
          {thirdParty.map((d) => (
            <li key={d.name}>
              <a href={d.url} target="_blank" rel="noopener noreferrer">
                <strong>{d.name}</strong>
              </a>{" "}
              — {d.license}. {d.note}
            </li>
          ))}
        </ul>
        <p className="text-sm text-muted-foreground">
          Las marcas y nombres de terceros pertenecen a sus respectivos titulares. Heardy no está
          afiliado a ninguno de estos proyectos o servicios ni patrocinado por ellos.
        </p>
      </LegalSection>

      <LegalSection id="web" title="Este sitio web">
        <ul>
          {webDeps.map((d) => (
            <li key={d.name}>
              <a href={d.url} target="_blank" rel="noopener noreferrer">
                <strong>{d.name}</strong>
              </a>{" "}
              — {d.license}.
            </li>
          ))}
        </ul>
        <p>
          Las animaciones proceden de{" "}
          <a href="https://lottiefiles.com" target="_blank" rel="noopener noreferrer">
            LottieFiles
          </a>{" "}
          y se usan bajo la{" "}
          <a href="https://lottiefiles.com/page/license" target="_blank" rel="noopener noreferrer">
            Lottie Simple License
          </a>
          :
        </p>
        <ul>
          {Object.entries(lottie).map(([key, a]) => (
            <li key={key}>
              <a href={a.source} target="_blank" rel="noopener noreferrer">
                {key}
              </a>{" "}
              — autor: {a.author}.
            </li>
          ))}
        </ul>
      </LegalSection>
    </LegalPage>
  );
}
