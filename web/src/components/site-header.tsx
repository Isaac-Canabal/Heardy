"use client";

import Image from "next/image";
import Link from "next/link";
import { useState } from "react";
import { MenuIcon } from "lucide-react";

import { GithubIcon } from "@/components/github-icon";

import { Button, buttonVariants } from "@/components/ui/button";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet";
import { site } from "@/content/site";
import { cn } from "cn";

const navItems = [
  { href: "/#que-es", label: "Qué es" },
  { href: "/#como-funciona", label: "Cómo funciona" },
  { href: "/#escritorio-movil", label: "Escritorio y móvil" },
  { href: "/#codigo-abierto", label: "Código abierto" },
  { href: "/#descargas", label: "Descargas" },
];

export function SiteHeader() {
  const [open, setOpen] = useState(false);

  return (
    <header className="sticky top-0 z-40 border-b border-border/60 glass">
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-4">
        <Link href="/" className="flex items-center gap-2.5 font-semibold">
          <Image src="/icon.png" alt="" width={32} height={32} className="rounded-lg" priority />
          <span className="text-lg tracking-tight">{site.name}</span>
        </Link>

        <nav className="hidden items-center gap-1 md:flex" aria-label="Principal">
          {navItems.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className={cn(buttonVariants({ variant: "ghost", size: "sm" }), "text-muted-foreground")}
            >
              {item.label}
            </Link>
          ))}
          <a
            href={site.repoUrl}
            target="_blank"
            rel="noopener noreferrer"
            className={cn(buttonVariants({ variant: "outline", size: "sm" }), "ml-2 gap-1.5")}
          >
            <GithubIcon />
            GitHub
          </a>
        </nav>

        <Sheet open={open} onOpenChange={setOpen}>
          <SheetTrigger
            render={<Button variant="ghost" size="icon" className="md:hidden" aria-label="Abrir menú" />}
          >
            <MenuIcon />
          </SheetTrigger>
          <SheetContent side="right" className="w-72">
            <SheetHeader>
              <SheetTitle>{site.name}</SheetTitle>
            </SheetHeader>
            <nav className="flex flex-col gap-1 px-4" aria-label="Principal (móvil)">
              {navItems.map((item) => (
                <Link
                  key={item.href}
                  href={item.href}
                  onClick={() => setOpen(false)}
                  className="rounded-lg px-3 py-2 text-base hover:bg-muted"
                >
                  {item.label}
                </Link>
              ))}
              <a
                href={site.repoUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="mt-2 flex items-center gap-2 rounded-lg px-3 py-2 text-base hover:bg-muted"
              >
                <GithubIcon className="size-4" />
                GitHub
              </a>
            </nav>
          </SheetContent>
        </Sheet>
      </div>
    </header>
  );
}
