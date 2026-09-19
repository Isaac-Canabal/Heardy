"use client";

import type { ReactNode } from "react";

import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";

export type ShowcaseTabItem = {
  id: string;
  title: string;
  description: string;
  content: ReactNode;
};

export function ShowcaseTabs({ items }: { items: ShowcaseTabItem[] }) {
  if (items.length === 0) return null;
  return (
    <Tabs defaultValue={items[0].id} className="gap-8">
      <TabsList className="h-auto w-full flex-wrap justify-start gap-1 bg-transparent p-0">
        {items.map((item) => (
          <TabsTrigger
            key={item.id}
            value={item.id}
            className="h-auto flex-none rounded-full border border-border/60 px-4 py-2 text-sm data-active:border-brand-light/60 data-active:bg-brand/20 data-active:text-foreground dark:data-active:border-brand-light/60 dark:data-active:bg-brand/20"
          >
            {item.title}
          </TabsTrigger>
        ))}
      </TabsList>
      {items.map((item) => (
        <TabsContent key={item.id} value={item.id} className="space-y-8">
          <p className="max-w-3xl text-lg text-foreground/90">{item.description}</p>
          {item.content}
        </TabsContent>
      ))}
    </Tabs>
  );
}
