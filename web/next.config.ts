import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Sin AGENTS.md/CLAUDE.md autogenerados por `next dev` dentro de web/.
  agentRules: false,
  // Sitio estático: todas las rutas se prerrenderizan y `out/` se sirve tal
  // cual desde Cloudflare Workers (assets estáticos, ver wrangler.jsonc).
  output: "export",
  trailingSlash: true,
  // La optimización de imágenes de Next necesita servidor; en exportación
  // estática las imágenes se sirven como están.
  images: { unoptimized: true },
};

export default nextConfig;
