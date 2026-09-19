import Image from "next/image";
import { ImageIcon } from "lucide-react";
import { cn } from "cn";

import type { DeviceFrame, ShowcaseMedia } from "@/content/showcase";

const frameClass: Record<DeviceFrame, string> = {
  // 9:19.5 (móvil) y 16:9 (escritorio), como pide la sección de capturas.
  phone: "aspect-[9/19.5] w-full max-w-[240px] rounded-[2rem] border-[6px]",
  desktop: "aspect-video w-full max-w-3xl rounded-xl border-[6px]",
};

function Placeholder({ media }: { media: ShowcaseMedia }) {
  return (
    <div className="flex h-full w-full flex-col items-center justify-center gap-2 bg-[repeating-linear-gradient(135deg,rgba(167,139,250,0.08)_0_10px,transparent_10px_20px)] p-4 text-center">
      <ImageIcon className="size-8 text-brand-light/70" />
      <p className="text-xs font-medium text-muted-foreground">Próximamente</p>
      <p className="text-[0.65rem] text-muted-foreground/70">
        {media.device === "phone" ? "9:19.5" : "16:9"} · {media.kind === "video" ? "vídeo" : "imagen"}
      </p>
    </div>
  );
}

function MediaContent({ media }: { media: ShowcaseMedia }) {
  if (!media.src) return <Placeholder media={media} />;
  if (media.kind === "video") {
    return (
      <video
        className="h-full w-full object-cover"
        src={media.src}
        poster={media.poster}
        autoPlay
        loop
        muted
        playsInline
        preload="metadata"
        aria-label={media.alt}
      />
    );
  }
  return (
    <Image
      src={media.src}
      alt={media.alt}
      fill
      sizes={media.device === "phone" ? "240px" : "(min-width: 768px) 768px, 100vw"}
      className="object-cover"
    />
  );
}

export function MediaFrame({ media, className }: { media: ShowcaseMedia; className?: string }) {
  return (
    <figure
      className={cn(
        "relative mx-auto overflow-hidden border-[#2a2446] bg-[#0d0b18] shadow-[0_20px_60px_rgba(0,0,0,0.45)]",
        frameClass[media.device],
        className,
      )}
    >
      <MediaContent media={media} />
      <figcaption className="sr-only">{media.alt}</figcaption>
    </figure>
  );
}

/**
 * Conjunto de capturas/vídeos de una función. Recibe la lista de medios definida
 * en `src/content/showcase.ts`; combina móvil y escritorio en la misma fila.
 */
export function MediaShowcase({ media, className }: { media: ShowcaseMedia[]; className?: string }) {
  return (
    <div className={cn("flex flex-col items-center gap-6 md:flex-row md:flex-wrap md:items-end md:justify-center", className)}>
      {media.map((m, i) => (
        <MediaFrame key={`${m.device}-${i}`} media={m} className={m.device === "desktop" ? "md:basis-full md:max-w-3xl" : undefined} />
      ))}
    </div>
  );
}
