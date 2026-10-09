# Repository Guidelines

## Project Structure & Module Organization

Zigrupt is a Zig implementation of the LMAX Disruptor pattern. The public module starts at `src/root.zig`; `src/ring_buffer.zig` implements the event bus and sequencers, and `src/waiting_strategy.zig` defines waiting strategies. Tests live in `test/*.zig`, with shared helpers in `test/support/`. The cross-language performance suite is under `benchmarks/`; see `benchmarks/README.md` before changing or running it.

## Build, Test, and Development Commands

- `zig build` checks the default build configuration; this library has no executable target.
- `zig build test` runs the module test and every top-level `test/*.zig` file.
- `zig fmt src test build.zig` formats Zig sources; use `zig fmt --check src test build.zig` to check formatting without editing.
- `devbox shell` provides the pinned Zig 0.16.0 toolchain when Zig is not installed locally.
- `devbox run bench --standalone --smoke` runs a short Zig-only benchmark check on Linux. Use `devbox run bench --help` for other benchmark options.

## Coding Style & Naming Conventions

Follow `zig fmt` (four-space indentation) and existing Zig conventions: `snake_case` for files and local variables, `camelCase` for functions, and `PascalCase` for types. Keep public declarations in `src/root.zig` intentional. Document concurrency assumptions near atomic operations, especially ordering, sequence bounds, and producer/consumer ownership.

## Testing Guidelines

Use Zig's built-in `test` blocks and `std.testing`; there is no separate test framework or documented coverage threshold. Add focused tests to the matching `test/<feature>.zig` file, using descriptive test names such as `test "batch size must be nonzero"`. Cover both single- and multi-producer modes where behavior should agree, and include wraparound, backpressure, and lifecycle cases for ring-buffer changes. Run `zig build test` before submitting.

## Commit & Pull Request Guidelines

Recent commits use short, descriptive subjects, often imperative (for example, `Fix drain batching to check contiguous published events`); there is no enforced prefix scheme. Keep commits scoped to one change. In pull requests, explain the behavior changed, list verification commands, link a relevant issue when one exists, and include benchmark setup and results for performance claims.
