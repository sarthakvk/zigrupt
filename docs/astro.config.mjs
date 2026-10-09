import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

export default defineConfig({
  site: "https://sarthakvk.github.io",
  base: "/zigrupt",
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
      editLink: {
        baseUrl: "https://github.com/sarthakvk/zigrupt/edit/main/docs/",
      },
      sidebar: [
        { label: "Overview", slug: "index" },
        { label: "Getting started", slug: "getting-started" },
        { label: "Concepts", slug: "concepts" },
        {
          label: "Usage guides",
          items: [
            { slug: "guides/producers" },
            { slug: "guides/handlers" },
            { slug: "guides/batching" },
            { slug: "guides/ownership" },
            { slug: "guides/lifecycle" },
            { slug: "guides/waiting-strategies" },
          ],
        },
        {
          label: "Reference",
          items: [
            { slug: "reference/api" },
            { slug: "reference/configuration" },
          ],
        },
        {
          label: "Contributing",
          items: [
            { slug: "contributing/workflow" },
            { slug: "contributing/internals" },
          ],
        },
      ],
    }),
  ],
});
