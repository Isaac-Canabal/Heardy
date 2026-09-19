"use client";

import dynamic from "next/dynamic";
import { useState } from "react";
import { cn } from "cn";

import { lottie, type LottieKey } from "@/content/lottie";

const DotLottieReact = dynamic(
  () => import("@lottiefiles/dotlottie-react").then((m) => m.DotLottieReact),
  { ssr: false, loading: () => <EqualizerBars /> },
);

type Props = {
  name: LottieKey;
  className?: string;
  /** Texto para lectores de pantalla; la animación es decorativa por defecto. */
  label?: string;
};

/** Ecualizador CSS propio (colores de la marca): decorativo, y también el respaldo mientras carga una animación o si el CDN falla. */
export function EqualizerBars({ className }: { className?: string }) {
  return (
    <div
      aria-hidden
      className={cn("flex h-full w-full items-end justify-center gap-1.5 p-6", className)}
    >
      {[0, 1, 2, 3, 4, 5, 6].map((i) => (
        <span
          key={i}
          className="eq-bar block w-2.5 rounded-full bg-linear-to-t from-brand to-brand-cyan"
          style={{ height: `${40 + ((i * 17) % 50)}%`, animationDelay: `${i * 0.12}s` }}
        />
      ))}
    </div>
  );
}

export function LottieAnimation({ name, className, label }: Props) {
  const [failed, setFailed] = useState(false);
  const animation = lottie[name];

  return (
    <div
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
      className={cn("relative", className)}
    >
      {failed ? (
        <EqualizerBars />
      ) : (
        <DotLottieReact
          src={animation.src}
          loop
          autoplay
          className="h-full w-full"
          dotLottieRefCallback={(instance) => {
            instance?.addEventListener("loadError", () => setFailed(true));
          }}
        />
      )}
    </div>
  );
}
