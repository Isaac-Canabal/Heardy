import Image from "next/image";
import {
  CaptionsIcon,
  ChartNoAxesColumnIcon,
  CloudOffIcon,
  FolderOpenIcon,
  InboxIcon,
  LanguagesIcon,
  LaptopIcon,
  ListMusicIcon,
  RefreshCwIcon,
  ScaleIcon,
  SmartphoneIcon,
  UsersIcon,
  WifiOffIcon,
} from "lucide-react";

import { DownloadButtons } from "@/components/download-dialog";
import { GithubIcon } from "@/components/github-icon";
import { EqualizerBars, LottieAnimation } from "@/components/lottie-animation";
import { MediaShowcase } from "@/components/media-showcase";
import { ShowcaseTabs } from "@/components/showcase-tabs";
import { Badge } from "@/components/ui/badge";
import { buttonVariants } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { downloads } from "@/content/downloads";
import { showcase } from "@/content/showcase";
import { site } from "@/content/site";
import { cn } from "cn";

const whatIs = [
  {
    icon: FolderOpenIcon,
    title: "Tu música, en tu carpeta",
    text: "Eliges una carpeta del dispositivo y esa es tu biblioteca. Los archivos siguen siendo tuyos, donde siempre estuvieron.",
  },
  {
    icon: WifiOffIcon,
    title: "Funciona sin conexión",
    text: "Reproducción, playlists, búsqueda y estadísticas funcionan sin internet y sin cuenta. Nada te pide iniciar sesión para escuchar.",
  },
  {
    icon: CaptionsIcon,
    title: "Letras sincronizadas y traducidas",
    text: "Letras línea a línea al ritmo de la canción, con traducción opcional para entender lo que escuchas.",
  },
  {
    icon: CloudOffIcon,
    title: "El audio nunca sale de tu dispositivo",
    text: "La cuenta es opcional y solo sincroniza un índice (títulos, playlists, historial). Ningún servidor guarda tus canciones.",
  },
];

const features = [
  { icon: ListMusicIcon, label: "Playlists y cola de reproducción" },
  { icon: LanguagesIcon, label: "Traducción de letras" },
  { icon: ChartNoAxesColumnIcon, label: "Estadísticas de escucha" },
  { icon: InboxIcon, label: "Bandeja de importación" },
  { icon: RefreshCwIcon, label: "Sincronización opcional del índice" },
  { icon: UsersIcon, label: "Amigos y \"escuchando ahora\"" },
];

export default function HomePage() {
  return (
    <>
      {/* Hero */}
      <section className="relative overflow-hidden">
        <div className="mx-auto grid max-w-6xl items-center gap-10 px-4 pt-16 pb-20 md:grid-cols-[1.1fr_0.9fr] md:pt-24">
          <div className="space-y-7">
            <Badge variant="outline" className="border-brand-light/40 text-brand-light">
              Android · Windows · Código abierto
            </Badge>
            <div className="flex items-center gap-4">
              <Image
                src="/icon.png"
                alt=""
                width={72}
                height={72}
                priority
                className="rounded-2xl shadow-[0_10px_40px_rgba(124,58,237,0.45)]"
              />
              <h1 className="text-5xl font-semibold tracking-tight md:text-6xl">
                <span className="text-gradient">{site.name}</span>
              </h1>
            </div>
            <p className="text-2xl font-medium text-foreground/95 md:text-3xl">{site.tagline}</p>
            <p className="max-w-xl text-lg text-muted-foreground">
              Un reproductor de música local, sin suscripciones ni catálogos ajenos: organiza tu
              colección por carpetas y playlists, sigue las letras sincronizadas y descubre qué
              escuchas más. Todo en tu teléfono o en tu PC.
            </p>
            <DownloadButtons />
            <p className="text-xs text-muted-foreground">
              Gratis, sin anuncios ni analítica. Licencia MIT.
            </p>
          </div>

          <div className="relative mx-auto aspect-square w-full max-w-md">
            <div className="absolute inset-8 rounded-full bg-brand/25 blur-3xl" aria-hidden />
            <LottieAnimation name="listening" className="relative h-full w-full" />
          </div>
        </div>
      </section>

      {/* Qué es Heardy */}
      <section id="que-es" className="scroll-mt-20">
        <div className="mx-auto max-w-6xl px-4 py-16">
          <SectionHeading
            eyebrow="Qué es Heardy"
            title="Un reproductor que respeta tu colección"
            text="Heardy no es un servicio de streaming: es la forma más cómoda de escuchar la música que ya tienes."
          />
          <div className="mt-10 grid gap-4 sm:grid-cols-2">
            {whatIs.map((item) => (
              <Card key={item.title} className="glass border-0">
                <CardHeader>
                  <div className="mb-2 flex size-10 items-center justify-center rounded-xl bg-brand/20 text-brand-light">
                    <item.icon className="size-5" />
                  </div>
                  <CardTitle className="text-lg">{item.title}</CardTitle>
                  <CardDescription className="text-base leading-relaxed">{item.text}</CardDescription>
                </CardHeader>
              </Card>
            ))}
          </div>
          <ul className="mt-8 flex flex-wrap gap-2">
            {features.map((f) => (
              <li key={f.label}>
                <Badge variant="secondary" className="gap-1.5 py-1.5 pr-3 pl-2 text-sm font-normal">
                  <f.icon className="size-3.5 text-brand-light" />
                  {f.label}
                </Badge>
              </li>
            ))}
          </ul>
        </div>
      </section>

      {/* Cómo funciona */}
      <section id="como-funciona" className="scroll-mt-20 border-y border-border/60 bg-black/20">
        <div className="mx-auto max-w-6xl px-4 py-16">
          <div className="flex flex-col gap-8 md:flex-row md:items-end md:justify-between">
            <SectionHeading
              eyebrow="Cómo funciona"
              title="De una carpeta a una biblioteca"
              text="Cada función, en pantalla. Las capturas y vídeos de esta sección se irán completando."
            />
            <EqualizerBars className="h-24 w-40 shrink-0 md:h-28 md:w-48" />
          </div>
          <div className="mt-10">
            <ShowcaseTabs
              items={showcase.map((item) => ({
                id: item.id,
                title: item.title,
                description: item.description,
                content: <MediaShowcase media={item.media} />,
              }))}
            />
          </div>
          <p className="mt-8 max-w-2xl text-sm text-muted-foreground">
            ¿Tienes un enlace en vez de un archivo? Heardy también puede importar audio desde un
            enlace mediante un servidor propio opcional; el archivo resultante entra en tu carpeta
            como cualquier otro, bajo tu responsabilidad y según los{" "}
            <a href="/terminos" className="underline underline-offset-2 hover:text-foreground">
              Términos de uso
            </a>
            .
          </p>
        </div>
      </section>

      {/* Escritorio y móvil */}
      <section id="escritorio-movil" className="scroll-mt-20">
        <div className="mx-auto max-w-6xl px-4 py-16">
          <SectionHeading
            eyebrow="Escritorio y móvil"
            title="La misma biblioteca, dos formas de escucharla"
            text="Heardy es una sola app con dos interfaces: una pensada para el pulgar y otra para la pantalla grande."
          />
          <div className="mt-10 grid gap-6 md:grid-cols-2">
            <Card className="glass border-0">
              <CardHeader>
                <div className="mb-2 flex size-10 items-center justify-center rounded-xl bg-brand/20 text-brand-light">
                  <SmartphoneIcon className="size-5" />
                </div>
                <CardTitle className="text-xl">Android</CardTitle>
                <CardDescription className="text-base leading-relaxed">
                  Navegación por pestañas, mini reproductor persistente, controles en la pantalla de
                  bloqueo y reproducción en segundo plano. Elige la carpeta una sola vez y Heardy se
                  encarga del resto.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <MediaShowcase
                  media={[{ kind: "image", src: "/media/movil-reproductor.jpg", alt: "Heardy en Android", device: "phone" }]}
                />
              </CardContent>
            </Card>
            <Card className="glass border-0">
              <CardHeader>
                <div className="mb-2 flex size-10 items-center justify-center rounded-xl bg-brand-cyan/20 text-brand-cyan">
                  <LaptopIcon className="size-5" />
                </div>
                <CardTitle className="text-xl">Windows</CardTitle>
                <CardDescription className="text-base leading-relaxed">
                  Interfaz de tres columnas — playlists, canciones y panel de reproducción —, barra de
                  título propia, control de volumen y atajos de teclado. Un instalador y listo.
                </CardDescription>
              </CardHeader>
              <CardContent>
                <MediaShowcase
                  media={[{ kind: "image", src: null, alt: "Heardy en Windows", device: "desktop" }]}
                />
              </CardContent>
            </Card>
          </div>
        </div>
      </section>

      {/* Código abierto */}
      <section id="codigo-abierto" className="scroll-mt-20 border-y border-border/60 bg-black/20">
        <div className="mx-auto grid max-w-6xl items-center gap-10 px-4 py-16 md:grid-cols-[1fr_auto]">
          <div>
            <SectionHeading
              eyebrow="Código abierto"
              title="Puedes leer cada línea"
              text="Heardy se publica bajo licencia MIT. El código de la app y del servidor opcional está en GitHub: revísalo, compílalo tú mismo o propón mejoras."
            />
            <div className="mt-8 flex flex-wrap gap-3">
              <a
                href={site.repoUrl}
                target="_blank"
                rel="noopener noreferrer"
                className={cn(buttonVariants({ variant: "outline", size: "lg" }), "h-11 gap-2 rounded-xl px-5 text-base")}
              >
                <GithubIcon className="size-5" />
                Ver en GitHub
              </a>
              <a
                href="/licencias"
                className={cn(buttonVariants({ variant: "ghost", size: "lg" }), "h-11 gap-2 rounded-xl px-5 text-base")}
              >
                <ScaleIcon className="size-5" />
                Licencia MIT y créditos
              </a>
            </div>
          </div>
          <LottieAnimation name="headphones" className="mx-auto size-48 md:size-64" />
        </div>
      </section>

      {/* Descargas */}
      <section id="descargas" className="scroll-mt-20">
        <div className="mx-auto max-w-6xl px-4 py-20">
          <div className="relative overflow-hidden rounded-3xl border border-border/60 bg-linear-to-br from-brand/25 via-card to-brand-cyan/10 p-8 md:p-12">
            <div className="absolute top-4 right-4 hidden size-40 opacity-80 md:block" aria-hidden>
              <LottieAnimation name="download" className="h-full w-full" />
            </div>
            <div className="relative max-w-2xl space-y-6">
              <SectionHeading
                eyebrow="Descargas"
                title="Empieza a escuchar"
                text="Elige tu plataforma. Antes de descargar te mostraremos un resumen de los términos de uso."
              />
              <DownloadButtons />
              <dl className="grid gap-3 text-sm text-muted-foreground sm:grid-cols-2">
                {Object.values(downloads).map((d) => (
                  <div key={d.platform} className="rounded-xl bg-black/20 p-4">
                    <dt className="font-medium text-foreground">{d.label}</dt>
                    <dd>
                      Versión {d.version} · {d.approxSize}
                      <br />
                      {d.requirements}
                    </dd>
                  </div>
                ))}
              </dl>
            </div>
          </div>
        </div>
      </section>
    </>
  );
}

function SectionHeading({ eyebrow, title, text }: { eyebrow: string; title: string; text: string }) {
  return (
    <div className="max-w-2xl space-y-3">
      <p className="text-sm font-medium tracking-wide text-brand-light uppercase">{eyebrow}</p>
      <h2 className="text-3xl font-semibold tracking-tight md:text-4xl">{title}</h2>
      <p className="text-lg text-muted-foreground">{text}</p>
    </div>
  );
}
