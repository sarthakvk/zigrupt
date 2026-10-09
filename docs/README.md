# Documentation site

The site uses Astro Starlight with ordinary Markdown and its standard navigation,
search, highlighting, and theme controls. No custom frontend is required.

Use Node **24.18.0** (`.node-version`) and npm **11.16.0**. From the repository root:

```sh
npm --prefix docs ci
npm --prefix docs run check
npm --prefix docs run dev
```

Open <http://localhost:4321/zigrupt/>. For the production output, use
`npm --prefix docs run preview` after building; production preview includes search.
`docs/dist/`, `.astro/`, and `node_modules/` are generated and ignored by Git.
The Zig package uses a separate file allowlist; it has no Node dependency.

## Maintaining content

- Pages: `src/content/docs/`; sidebar/site/base: `astro.config.mjs`.
- Source of truth: implementation, existing tests, and [behavior checklist](behavior-checklist.md).
- Code blocks: generated from `examples/` by `node docs/scripts/sync-snippets.mjs`.
- Shared prose: generated from `bench/README.md` and `CONTRIBUTING.md` with `include` markers.
- `npm --prefix docs run check:snippets` checks synchronization without writing.
- `npm --prefix docs run check` checks snippets, builds, then checks internal links,
  fragments, referenced assets/CSS URLs, repository-document links, and search artifacts.
- Browser review: preview the production build; follow sidebar and next/previous
  navigation, search for “backpressure”, and inspect the diagram on desktop and mobile.

Node dependencies are pinned and locked; use `npm ci` to reproduce them. When
upgrading, update exact versions and the lockfile together, run all checks, and
repeat browser review. Tooling references:
[Starlight setup](https://starlight.astro.build/manual-setup/),
[Markdown authoring](https://starlight.astro.build/guides/authoring-content/), and
[Astro on GitHub Pages](https://docs.astro.build/en/guides/deploy/github/).

## Hosting status

Pages configuration targets `https://sarthakvk.github.io/zigrupt/`; that address
is a proposed target, not a claim of a live site. Deployment is manual and only
from `main`. Enabling Pages and publication require a maintainer decision; neither
is performed by the documentation checks. See [CONTRIBUTING.md](../CONTRIBUTING.md)
for the activation procedure after approval.
