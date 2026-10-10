import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import githubDarkColorblind from "./src/themes/github-dark-colorblind.json";
import githubLightColorblind from "./src/themes/github-light-colorblind.json";

export default defineConfig({
  site: "https://zigrupt.sarthakvk.com",
  base: process.env.DOCS_BASE || "/",
  trailingSlash: "always",
  integrations: [
    starlight({
      title: "zigrupt",
      description: "A Disruptor-inspired event bus for Zig",
      logo: {
        src: "../docs/assets/zigrupt_logo.png",
        alt: "Zigrupt",
        replacesTitle: true,
      },
      favicon: "/favicon.png",
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/sarthakvk/zigrupt",
        },
      ],
      components: { Header: "./src/components/Header.astro" },
      customCss: ["./src/styles/theme.css"],
      expressiveCode: {
        themes: [githubDarkColorblind, githubLightColorblind],
      },
      sidebar: [
        { slug: "index", label: "Home" },
        { slug: "getting-started", label: "Getting Started" },
        { slug: "concepts", label: "Concepts" },
        {
          label: "Guides",
          items: [
            { slug: "guides/producers", label: "Producers & Broadcast" },
            { slug: "guides/handlers", label: "Handlers & Context" },
            { slug: "guides/ownership", label: "Event Ownership" },
            { slug: "guides/batching", label: "Batching & Acknowledgements" },
            { slug: "guides/waiting-strategies", label: "Waiting Strategies" },
            { slug: "guides/lifecycle", label: "Lifecycle" },
          ],
        },
        {
          label: "Reference",
          items: [
            { slug: "reference/api", label: "Public API" },
            { slug: "reference/configuration", label: "Configuration" },
          ],
        },
        { slug: "performance", label: "Performance" },
        {
          label: "Contributing",
          items: [
            { slug: "contributing/workflow", label: "Contributor Workflow" },
            { slug: "contributing/internals", label: "Implementation Tour" },
          ],
        },
      ],
    }),
  ],
});
