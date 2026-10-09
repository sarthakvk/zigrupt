# Contributing to zigrupt

zigrupt is a growing Disruptor implementation. Keep changes focused and document
implemented behavior as it evolves; discuss future capabilities separately from
what callers can use today.

## Setup

Install Zig **0.16.0** and verify `zig version`. An optional Devbox environment is
available via `devbox shell`. Its current `zig@latest` selection can drift, so
verify that it resolves to 0.16.0 before reproducing CI. Run the commands below
directly; the existing Devbox `test` script is a placeholder.

Library work requires no Node. The standalone installation check additionally
uses Python 3. Documentation work uses Node **24.18.0** and npm **11.16.0**, with
exact site dependencies in `docs/package.json` and `docs/package-lock.json`.

## Library and example checks

From the repository root:

```sh
zig fmt --check build.zig build.zig.zon src test bench examples
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
zig build test-bench
zig build bench -- --events_per_publisher=1000 --repetitions=2 --min_duration_ms=1
zig build bench -- --publishers=2 --consumers=2 --max_batch=8
```

The short run is only a functional check. Read
[bench/README.md](https://github.com/sarthakvk/zigrupt/blob/main/bench/README.md)
for measurement boundaries, placement, calibration, and latency caveats. Report
hardware, Zig version, flags, CPU mapping, and repeated results when discussing
performance changes.

## Documentation workflow

From the repository root:

```sh
npm --prefix docs ci
node docs/scripts/sync-snippets.mjs
npm --prefix docs run check
npm --prefix docs run dev
```

Open `http://localhost:4321/zigrupt/`. For a production preview, first run the
check/build command, then `npm --prefix docs run preview` and open the same URL.
Search is indexed in the production build; validate search using that preview.

Author ordinary Markdown under `docs/src/content/docs/`. New pages need a title
and description in frontmatter and a sidebar entry in `docs/astro.config.mjs`.
Use `/zigrupt/.../` links for site routes and relative paths for source assets.
The production link check verifies pages, fragments, referenced local assets,
CSS URLs, repository-document relative links, and the search index's presence.
It does not check external-site uptime or exercise a browser.

Canonical code lives in `examples/`. Keep `snippet` marker pairs around generated
code in README and docs; run the synchronization command after edits, and commit
its output. The performance page similarly includes the benchmark README, and
the workflow page includes this guide. Do not hand-edit generated regions.
`npm run build` checks for stale snippets before building, so CI detects drift.

When a change affects public behavior, update the applicable guides, handwritten
reference, source comments, canonical examples, and relevant tests in the same
change. Update the evidence map in `docs/behavior-checklist.md`. This initial
documentation change deliberately leaves library source and tests untouched.
Distinguish tested guarantees from source-reviewed rules, and reassess API
reference generation as the library grows.

## Issues and pull requests

For issues, include the Zig version, platform, a small reproducer, expected and
observed behavior, and whether single- or multi-producer mode is involved. For
performance reports, include the measurement setup and caveats above.

For pull requests, explain the concrete problem and resulting behavior, describe
validation, and identify any public-contract changes. Keep unrelated redesigns
separate. CI runs the existing tests, formatting, examples, standalone consumer,
and documentation checks. Concurrency changes should have focused evidence for
ordering, backpressure, and shutdown where relevant.

## Publishing configuration

GitHub Pages is the proposed host, with base path `/zigrupt/`. The
`.github/workflows/docs-pages.yml` workflow is **manual only** and restricted to
`main`. It builds and checks the site before deployment. Pushes and pull requests
run validation but never publish.

Enabling Pages and the first publication remain maintainer decisions. Once
approved, select GitHub Actions as the Pages source in repository settings, review
the `github-pages` environment, and manually run the publishing workflow on
`main`. The workflow does not enable Pages automatically. After a successful
publication, add the confirmed public URL to the README. A custom domain or a
change of repository owner/name requires reviewing `site`, `base`, content links,
and the link check together. No new security or community policy is established
by this documentation work.
