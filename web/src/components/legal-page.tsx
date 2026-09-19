import type { ReactNode } from "react";

import { site } from "@/content/site";

type Props = {
  title: string;
  intro?: string;
  children: ReactNode;
};

export function LegalPage({ title, intro, children }: Props) {
  return (
    <article className="mx-auto max-w-3xl px-4 py-14">
      <header className="space-y-4">
        <h1 className="text-4xl font-semibold tracking-tight">{title}</h1>
        <p className="text-sm text-muted-foreground">
          Última actualización: {site.legalUpdatedAt} · Operador: {site.operatorName} ({site.operatorLocation})
        </p>
        {intro ? <p className="text-lg text-muted-foreground">{intro}</p> : null}
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
