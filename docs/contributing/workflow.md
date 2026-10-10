---
title: Contributor workflow
description: Reproduce checks, edit documentation, and review publication configuration.
---

<!-- include: CONTRIBUTING.md -->
zigrupt is a growing Disruptor implementation. Keep changes focused and document
implemented behavior as it evolves; discuss future capabilities separately from
what callers can use today.

## Setup

Install Zig **0.16.0** and verify `zig version`. An optional Devbox environment is
available via `devbox shell`. Its current `zig@0.16.0` selection can drift, so
verify that it resolves to 0.16.0 before reproducing CI. Run the commands below
directly; the existing Devbox `test` script is a placeholder.

Library work requires no Node. The standalone installation check additionally
uses Python 3. Documentation work uses Node **24.18.0** and npm **11.16.0**, with
exact site dependencies in `.docs-site/package.json` and `.docs-site/package-lock.json`.

## Library and example checks

From the repository root:

```sh
zig fmt --check build.zig build.zig.zon src test examples
zig build test --summary all
zig build check-examples --summary all
python3 scripts/check-install.py
```

Use `zig fmt` without `--check` on files you change. The example step compiles and
executes six standalone programs with explicit result checks. For individual
programs use `zig build example-basic`, `example-broadcast`,
`example-multi_producer`, `example-batching`, `example-context`, or
`example-waiting_strategy`. `zig build examples` only compiles them.

The installation check creates a temporary consumer outside the checkout,
packages the manifest's `.paths` allowlist, fetches a hashed archive dependency,
then builds and executes the canonical first program. It checks the package
boundary without a network dependency and removes its temporary project on exit.
Node dependencies and generated site assets are excluded from the Zig package.

## Benchmarks

```sh
devbox run bench --standalone --smoke
devbox run bench --help
```

The short run is only a functional check. Read
[benchmarks/README.md](https://github.com/sarthakvk/zigrupt/blob/main/benchmarks/README.md)
for measurement boundaries, placement, calibration, and latency caveats. Report
hardware, Zig version, flags, CPU mapping, and repeated results when discussing
performance changes.

## Documentation workflow

From the repository root:

```sh
npm --prefix .docs-site ci
node .docs-site/scripts/sync-snippets.mjs
npm --prefix .docs-site run check
npm --prefix .docs-site run dev
```

Open `http://localhost:4321/`. For a production preview, first run the
check/build command, then `npm --prefix .docs-site run preview` and open the same URL.
Search is indexed in the production build; validate search using that preview.

Author ordinary Markdown under `docs/`, using folders for the site hierarchy.
New pages need a title and description in frontmatter. Add each new page to the
ordered sidebar in `.docs-site/astro.config.mjs`.
Use `/.../` links for site routes and relative paths for source assets.
The production link check verifies pages, fragments, referenced local assets,
CSS URLs, repository-document relative links, and the search index's presence.
It does not check external-site uptime or exercise a browser.

Canonical code lives in `examples/`. Keep `snippet` marker pairs around generated
code in README and docs; run the synchronization command after edits, and commit
its output. The workflow page includes this guide. Do not hand-edit generated regions.
`npm run build` checks for stale snippets before building, so CI detects drift.

When a change affects public behavior, update the applicable guides, handwritten
reference, source comments, canonical examples, and relevant tests in the same
change. Distinguish tested guarantees from source-reviewed rules, and reassess
API reference generation as the library grows.

## Issues and pull requests

For issues, include the Zig version, platform, a small reproducer, expected and
observed behavior, and whether single- or multi-producer mode is involved. For
performance reports, include the measurement setup and caveats above.

For pull requests, explain the concrete problem and resulting behavior, describe
validation, and identify any public-contract changes. Keep unrelated redesigns
separate. CI runs the existing tests, formatting, examples, and standalone consumer
on every push and pull request. Documentation checks run only when docs, site
tooling, examples, included or checked Markdown, or the docs-related workflows
change. Concurrency changes should have focused evidence for ordering,
backpressure, and shutdown where relevant.

## Publishing configuration

Cloudflare Pages serves <https://zigrupt.sarthakvk.com/> from the site root. The
`.github/workflows/docs-pages.yml` builds, checks, and publishes the site on pushes
to `main` that change documentation inputs (the same paths used by CI's docs
filter). Release tags matching `vX.Y.Z` and manual runs always publish, even when
no documentation inputs changed, so new release archives are included.
Pull requests run validation without publishing. The site root shows the current
`main` docs. Each release tag containing `docs/index.md` gets an
archived site at `/<tag>/`; the version menu links to these archives.
The build uses the Markdown and images committed in each tag, so editing `main`
does not rewrite released documentation.

The Cloudflare Pages project is `zigrupt`, with `main` as its production branch.
The GitHub Actions workflow uses repository variable `CLOUDFLARE_ACCOUNT_ID` and
repository secret `CLOUDFLARE_API_TOKEN`. Create the token in Cloudflare with
Account > Cloudflare Pages > Edit access to this account, then store it as a
GitHub Actions secret. Keep the token out of commits and chat. The custom domain
must be attached to the Pages project. Cloudflare DNS has a `zigrupt` CNAME
pointing to `zigrupt.pages.dev`. A change of domain or repository owner/name
requires reviewing the site URL, base path, content links, and link checker.
<!-- end:CONTRIBUTING.md -->
