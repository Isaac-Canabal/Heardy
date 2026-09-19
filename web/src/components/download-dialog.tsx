"use client";

import Link from "next/link";
import { useId, useState } from "react";
import { DownloadIcon, MonitorIcon, SmartphoneIcon } from "lucide-react";
import { cn } from "cn";

import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { downloads, type Platform } from "@/content/downloads";
import { hasValidAcceptance, recordAcceptance } from "@/lib/terms-acceptance";

const termsSummary = [
  "Heardy es un reproductor de música local: reproduce archivos que ya están en tu dispositivo y no aloja ni distribuye audio.",
  "Todo el contenido que reproduces o importas es tu responsabilidad: debes tener derecho sobre él y respetar la ley de derechos de autor. Si lo incumples, respondes tú, no el operador.",
  "La cuenta es opcional. Si la creas, sincroniza un índice de tu biblioteca (títulos, artistas, playlists) y tu historial; nunca el audio.",
  "Uso personal y no comercial. Debes tener al menos 14 años, o la mayoría de edad de tu país si es superior.",
  "La app se ofrece \"tal cual\", sin garantías, bajo licencia MIT. Las controversias se resuelven por arbitraje en Colombia (opcional si eres consumidor). El producto se desarrolla con ayuda de inteligencia artificial, sin usar datos de usuarios.",
];

function startDownload(url: string, fileName: string) {
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = fileName;
  anchor.rel = "noopener";
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
}

type Props = {
  platform: Platform;
  variant?: "default" | "outline";
  className?: string;
};

export function DownloadButton({ platform, variant = "default", className }: Props) {
  const target = downloads[platform];
  const [open, setOpen] = useState(false);
  const [accepted, setAccepted] = useState(false);
  const checkboxId = useId();
  const Icon = platform === "android" ? SmartphoneIcon : MonitorIcon;

  const handleClick = () => {
    if (hasValidAcceptance()) {
      startDownload(target.url, target.fileName);
      return;
    }
    setAccepted(false);
    setOpen(true);
  };

  const handleConfirm = () => {
    if (!accepted) return;
    recordAcceptance();
    setOpen(false);
    startDownload(target.url, target.fileName);
  };

  return (
    <>
      <Button
        type="button"
        variant={variant}
        size="lg"
        onClick={handleClick}
        data-download={platform}
        className={cn(
          "h-12 gap-2 rounded-xl px-5 text-base",
          variant === "default" &&
            "bg-linear-to-r from-brand to-brand-cyan text-white shadow-[0_8px_24px_rgba(124,58,237,0.35)] hover:opacity-90",
          className,
        )}
      >
        <Icon className="size-5" />
        <span className="flex flex-col items-start leading-tight">
          <span>Descargar para {platform === "android" ? "Android" : "Windows"}</span>
          <span className="text-[0.7rem] font-normal opacity-80">
            {platform === "android" ? "APK" : "Instalador"} · {target.approxSize}
          </span>
        </span>
      </Button>

      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="sm:max-w-lg" aria-describedby={undefined}>
          <DialogHeader>
            <DialogTitle>Antes de descargar {target.label}</DialogTitle>
            <DialogDescription>
              Resumen de los puntos clave. El texto completo está en los{" "}
              <Link href="/terminos" target="_blank">
                Términos de uso
              </Link>{" "}
              y la{" "}
              <Link href="/privacidad" target="_blank">
                Política de privacidad
              </Link>
              .
            </DialogDescription>
          </DialogHeader>

          <ul className="space-y-2 text-sm text-foreground/90">
            {termsSummary.map((line) => (
              <li key={line} className="flex gap-2">
                <span aria-hidden className="mt-2 size-1.5 shrink-0 rounded-full bg-brand-light" />
                <span>{line}</span>
              </li>
            ))}
          </ul>

          <dl className="grid grid-cols-2 gap-x-4 gap-y-1 rounded-lg bg-muted/60 p-3 text-xs text-muted-foreground">
            <dt>Archivo</dt>
            <dd className="text-right font-mono text-foreground/80">{target.fileName}</dd>
            <dt>Versión</dt>
            <dd className="text-right text-foreground/80">{target.version}</dd>
            <dt>Tamaño aproximado</dt>
            <dd className="text-right text-foreground/80">{target.approxSize}</dd>
            <dt>Requisitos</dt>
            <dd className="text-right text-foreground/80">{target.requirements}</dd>
          </dl>

          <label
            htmlFor={checkboxId}
            className="flex cursor-pointer items-start gap-3 rounded-lg border border-border p-3 text-sm"
          >
            <Checkbox
              id={checkboxId}
              checked={accepted}
              onCheckedChange={(checked) => setAccepted(checked === true)}
              className="mt-0.5"
            />
            <span>
              He leído y acepto los{" "}
              <Link href="/terminos" target="_blank" className="underline underline-offset-2">
                Términos de uso
              </Link>{" "}
              y la{" "}
              <Link href="/privacidad" target="_blank" className="underline underline-offset-2">
                Política de privacidad
              </Link>
              .
            </span>
          </label>

          <DialogFooter>
            <Button type="button" variant="ghost" onClick={() => setOpen(false)}>
              Cancelar
            </Button>
            <Button
              type="button"
              disabled={!accepted}
              onClick={handleConfirm}
              data-testid="confirm-download"
              className={cn(
                "gap-2",
                accepted && "bg-linear-to-r from-brand to-brand-cyan text-white hover:opacity-90",
              )}
            >
              <DownloadIcon />
              Descargar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

export function DownloadButtons({ className }: { className?: string }) {
  return (
    <div className={cn("flex flex-col gap-3 sm:flex-row", className)}>
      <DownloadButton platform="android" />
      <DownloadButton platform="windows" variant="outline" />
    </div>
  );
}

