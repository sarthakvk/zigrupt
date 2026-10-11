# Repository Guidelines

Read `current_task.md` if it exists for ongoing planning and cross-session
context; it is a local scratch-pad and must not be committed.

## Toolchain and verification

- Use Zig **0.16.0**; `devbox shell` supplies it, but verify `zig version`.
  `devbox run test` is a failing placeholder; run Zig commands directly. Node is
  only needed for the documentation site.
- Plain `zig build` has no compilation/test work attached to its default step.
  CI's library checks, from the repository root, are:

  ```sh
  zig fmt --check build.zig build.zig.zon src test examples
  zig build test --summary all
  zig build check-examples --summary all
  python3 scripts/check-install.py
  ```

- `zig build test` runs module tests and every top-level `test/*.zig` file as
  separate executables. There is no build-level test filter. Focus one file/test
  with:

  ```sh
  zig test --dep zigrupt -Mroot=test/event_bus_batch.zig \
    -Mzigrupt=src/root.zig --test-filter "batch size"
  ```

  Omit `--test-filter` to run the whole file. Run the full suite before submitting
  library changes.
- `zig build examples` only compiles examples; `zig build check-examples` executes
  all six with result checks. `zig build example-basic` runs one; other names are
  listed by `zig build --help`.
- `scripts/check-install.py` needs Python 3 and Zig. It tests an isolated, offline
  archive consumer using the `.paths` allowlist in `build.zig.zon`; keep that
  allowlist current when adding packaged files.

## Concurrency context

- `src/root.zig` is the public API. `src/event_bus.zig` owns publication, handler
  threads and lifecycle; `src/sequencer.zig` owns claims and slot reuse. Claim
  progress is **not** publication progress: multi-producer claims can complete out
  of order, so consumption/draining must check contiguous per-slot publication.
- Consumer counters identify the **next unread** sequence, starting at one; slot
  reuse is gated by the slowest handler. Preserve/document acquire/release
  ordering and producer/consumer ownership when changing atomics.
- Keep a running bus at a stable address. `start()`/`stop()` belong to the
  initializing thread; finish all producer calls before `stop()`, then `deinit()`.
  Handlers acknowledge a consumed prefix; zero retries and can block shutdown.
  Callback slices are borrowed, and pointers inside copied events remain
  caller-owned.
- For ring-buffer changes, cover single/multi-producer agreement, wraparound,
  backpressure and lifecycle. Reuse `test/support/synchronization.zig`
  gates/counters for thread coordination without timing assumptions.

## Documentation and benchmarks

- Author site pages in `docs/`; `.docs-site/` is the separate Astro/Starlight npm
  project (Node **24.18.0**, npm **11.16.0**). New pages need title/description
  frontmatter and an entry in `.docs-site/astro.config.mjs`'s ordered sidebar.
- README/docs regions marked `snippet` or `include` are generated. Edit their
  source (canonical code is in `examples/`), run
  `node .docs-site/scripts/sync-snippets.mjs`, and commit the synchronized output;
  do not hand-edit generated regions. Public behavior changes also need the
  applicable guides and handwritten `docs/reference/api.md` updated.
- Site checks: `npm --prefix .docs-site ci`, then
  `npm --prefix .docs-site run check` (stale snippets, production build,
  links/assets). Preview with `npm --prefix .docs-site run dev`; search requires
  the production build and `npm --prefix .docs-site run preview`. See
  `CONTRIBUTING.md` for publishing/version archives.
- Read `benchmarks/README.md` before benchmark work. On Linux,
  `devbox run bench --standalone --smoke` is a functional Zig-only check, not
  performance evidence; `--standalone` skips competitor builds/fetches.
  Performance cases need one physical core per producer/consumer and skip cases
  exceeding available cores. Report hardware, toolchain, flags, CPU mapping and
  repeated results for performance claims.
