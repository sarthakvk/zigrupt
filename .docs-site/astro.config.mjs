import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

export default defineConfig({
  site: "https://sarthakvk.github.io",
  base: process.env.DOCS_BASE || "/zigrupt",
  trailingSlash: "always",
  integrations: [
    starlight({
      title: "zigrupt",
      description: "A Disruptor-inspired event bus for Zig",
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/sarthakvk/zigrupt",
        },
      ],
      components: { SiteTitle: "./src/components/SiteTitle.astro" },
    }),
  ],
});
