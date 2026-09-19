import type { ReactNode } from "react";
import { TriangleAlertIcon } from "lucide-react";

import { site } from "@/content/site";

type Props = {
  title: string;
  intro?: string;
  children: ReactNode;
  /** Muestra el aviso de "borrador pendiente de revisión legal" (por defecto sí). */
  draft?: boolean;
};

export function LegalPage({ title, intro, children, draft = true }: Props) {
  return (
    <article className="mx-auto max-w-3xl px-4 py-14">
      <header className="space-y-4">
        <h1 className="text-4xl font-semibold tracking-tight">{title}</h1>
        <p className="text-sm text-muted-foreground">
          Última actualización: {site.legalUpdatedAt} · Operador: {site.operatorName} ({site.operatorLocation})
        </p>
        {intro ? <p className="text-lg text-muted-foreground">{intro}</p> : null}
        {draft ? (
          <div
            role="note"
            className="flex gap-3 rounded-xl border border-amber-400/40 bg-amber-400/10 p-4 text-sm text-amber-100"
          >
            <TriangleAlertIcon className="mt-0.5 size-5 shrink-0 text-amber-300" />
            <div>
              <p className="font-semibold">Borrador pendiente de revisión legal</p>
              <p>
                Este texto es una versión preliminar redactada por el equipo del proyecto y todavía
                no ha sido revisada por un abogado. Puede cambiar antes de su versión definitiva. Los
                datos entre corchetes o marcados como PENDIENTE son marcadores de posición.
              </p>
            </div>
          </div>
        ) : null}
      </header>

      <div className="legal-body mt-10 space-y-8 text-[0.98rem] leading-relaxed text-foreground/90">
        {children}
      </div>
    </article>
  );
}

export function LegalSection({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section id={id} className="scroll-mt-24 space-y-3">
      <h2 className="text-2xl font-semibold tracking-tight">{title}</h2>
      {children}
    </section>
  );
}

export function LegalNote({ children }: { children: ReactNode }) {
  return (
    <p className="rounded-lg border border-dashed border-brand-light/40 bg-brand/10 px-3 py-2 text-sm text-brand-light">
      Nota de redacción: {children}
    </p>
  );
}
