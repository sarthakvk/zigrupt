import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import githubDarkColorblind from "./src/themes/github-dark-colorblind.json";
import githubLightColorblind from "./src/themes/github-light-colorblind.json";

export default defineConfig({
  site: "https://sarthakvk.github.io",
  base: process.env.DOCS_BASE || "/zigrupt",
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
      components: { SiteTitle: "./src/components/SiteTitle.astro" },
      customCss: ["./src/styles/theme.css"],
      expressiveCode: {
        themes: [githubDarkColorblind, githubLightColorblind],
      },
    }),
  ],
});
