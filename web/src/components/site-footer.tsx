import Image from "next/image";
import Link from "next/link";

import { GithubIcon } from "@/components/github-icon";
import { Separator } from "@/components/ui/separator";
import { site } from "@/content/site";

const legalLinks = [
  { href: "/terminos", label: "Términos de uso" },
  { href: "/privacidad", label: "Política de privacidad" },
  { href: "/licencias", label: "Licencias" },
];

export function SiteFooter() {
  return (
    <footer className="mt-24 border-t border-border/60">
      <div className="mx-auto max-w-6xl px-4 py-10">
        <div className="flex flex-col gap-8 md:flex-row md:items-start md:justify-between">
          <div className="max-w-sm space-y-3">
            <div className="flex items-center gap-2.5 font-semibold">
              <Image src="/icon.png" alt="" width={28} height={28} className="rounded-md" />
              <span>{site.name}</span>
            </div>
            <p className="text-sm text-muted-foreground">
              Reproductor de música local para Android y Windows. Tu música vive en tu
              dispositivo; el resto es opcional.
            </p>
          </div>

          <nav className="grid grid-cols-2 gap-x-12 gap-y-2 text-sm" aria-label="Pie de página">
            <div className="flex flex-col gap-2">
              <span className="font-medium">Legal</span>
              {legalLinks.map((l) => (
                <Link key={l.href} href={l.href} className="text-muted-foreground hover:text-foreground">
                  {l.label}
                </Link>
              ))}
            </div>
            <div className="flex flex-col gap-2">
              <span className="font-medium">Proyecto</span>
              <a
                href={site.repoUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1.5 text-muted-foreground hover:text-foreground"
              >
                <GithubIcon className="size-3.5" />
                Código en GitHub
              </a>
              <a href={site.licenseUrl} target="_blank" rel="noopener noreferrer" className="text-muted-foreground hover:text-foreground">
                Licencia MIT
              </a>
              <a href={`mailto:${site.contactEmail}`} className="text-muted-foreground hover:text-foreground">
                Contacto
              </a>
            </div>
          </nav>
        </div>

        <Separator className="my-8" />

        <p className="text-xs text-muted-foreground">
          © {new Date().getFullYear()} {site.name}. Código publicado bajo licencia MIT. Heardy no
          aloja ni distribuye audio.
        </p>
      </div>
    </footer>
  );
}
