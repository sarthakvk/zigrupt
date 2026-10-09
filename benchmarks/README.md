# Competitive benchmarks

Benchmarks the current **`src/ring_buffer.zig` EventBus**, Java Disruptor 4.0.0,
disruptor-rs 4.4.0, and the pinned Ziggy channel. Production code is unchanged.
Zigrupt uses available-event consumer batching with `max_batch_size = capacity`,
not a one-event cap; Java and Rust retain their native consumer batching. All
implementations still publish and perform validation/latency work per event.

- [Specification](SPEC.md): exact workload, measurement boundaries and caveats.
- [Measured report](results/baseline/REPORT.md): throughput, latency, resources,
  ratios, variability and exclusions.
- [Interactive notebook](visualize.ipynb): reusable charts for any run directory (see below).
- [Findings and follow-ups](FINDINGS.md).
- [Raw results](results/baseline/runs.jsonl), [summaries](results/baseline/summary.json),
  [CSV](results/baseline/summary.csv), [plot](results/baseline/throughput.svg).

## Reproduce

Requires Linux x86-64, devbox, `gh` (GitHub CLI), Git, and the usual Linux
`lscpu` utility. Fetching public source archives may require `gh auth login`.
The complete performance matrix needs **at least six physical cores of one
class on one socket**; SMT siblings do not count as separate physical cores.

All benchmark-only toolchains are **optional**, isolated in this directory's
`devbox.json` / `devbox.lock`. The root development environment is unchanged.
Ziggy has a second nested devbox because its pinned source requires Zig 0.15.2;
Zigrupt uses 0.16.0. Rust, Cargo, Python, GCC and the JDK are also pinned. No
Python packages, Gradle, Maven, Jupyter or plotting dependencies are needed to
build, run or report benchmarks. The optional notebook has its own dependencies.

From the repository root:

```sh
devbox run -c benchmarks build       # installs optional tools; fetches and verifies pinned sources
devbox run -c benchmarks test        # unit checks + real adapter/backpressure/latency tests

devbox run -c benchmarks -- python run.py --smoke --repeats 3 --output results/smoke-new

# Longer defaults: five processes per cell, 2 s target measurement, 3 s warmup.
devbox run -c benchmarks -- python run.py --output results/my-machine

devbox run -c benchmarks -- python report.py results/my-machine
```

Output paths are relative to `benchmarks/`. The runner **refuses to overwrite an
existing output directory**. It also refuses stale adapters/binaries or a
Zigrupt source tree changed since the build. Builds verify competitors against
both commit IDs and source-tree hashes in `sources.json` and honor `rust/Cargo.lock`.

**The checked-in baseline and findings are historical:** they predate the cached
sequencers and batch-consumption changes merged from `origin/main`. Their source
hashes remain in the saved manifest; they do not describe current performance.
Rebuild and collect a new run before making comparisons. Old raw data is retained,
not rewritten or mixed with new samples.

The checked-in baseline used:

```sh
devbox run -c benchmarks -- python run.py \
  --repeats 5 --seconds 1 --warm-seconds 2 --output results/baseline
```

The one-second setting is a short, host-local baseline, not a production latency
SLA. Use longer runs on an idle, thermally stable host to confirm tail behavior.
Do not run builds, tests or another benchmark concurrently with measured runs.
The suite records CPU placement/governors but does not change system policies,
isolate CPUs, disable SMT/turbo, or terminate other applications.

## Visualize a run in Jupyter

Use the single [visualize.ipynb](visualize.ipynb) notebook for every run; no
per-run notebooks are generated. Install the optional dependencies once
(Python 3.12+, commands from the repository root):

```sh
devbox run -c benchmarks -- python -m venv .venv
benchmarks/.venv/bin/python -m pip install -r benchmarks/notebook-requirements.txt
benchmarks/.venv/bin/jupyter lab benchmarks/visualize.ipynb
```

Set `BENCH_DIR` in the first code cell to your results directory and choose
**Run → Run All Cells**. The default is `results/baseline`. Absolute paths work
from anywhere; relative paths are checked against the kernel's working directory,
then `benchmarks/` (so launching from the repository root also works).
Optional `WORKLOADS`, `IMPLEMENTATIONS`, and `LATENCY_CONSUMER` settings narrow
the view. After changing settings, rerun all cells.

Charts show throughput, p50/p99/p99.9 latency at each common load, saturation CPU
and RSS, and throughput variability. Large, distinct shapes and a colorblind-friendly
palette identify implementations: **Zigrupt = square, Java = triangle, Rust = diamond,
Ziggy = plus**. Alternating background bands separate workloads; implementations
appear top-to-bottom in legend order within each band. Medians have min–max whiskers;
filled markers are rankable and hollow markers are unranked. The variability chart
shows CV instead of medians. Throughput is better farther right; latency and variability
are better farther left. Blocked and invalid records remain visible in the run overview.
Latency defaults to the worst consumer per run, with individual consumers
available through the setting. Missing data is not plotted as zero.

The notebook only reads `summary.json`, `manifest.json`, and `runs.jsonl`; it
neither runs benchmarks nor modifies their output. If a completed directory lacks
summaries, run `report.py` as above first. Keep the shared notebook's outputs
cleared when committing it. Do not run notebook analysis alongside measured runs.

## What runs

1. All 56 applicable implementation/workload combinations receive an exact-order,
   wraparound and slow-consumer backpressure preflight. Correctness-only tests
   may share physical cores; their timings are never ranked.
2. Ineligible performance topologies are explicitly recorded as **blocked**.
3. Calibration selects event counts. Five independent, shuffled throughput rounds
   measure completed unique publications and broadcast deliveries separately.
4. For each comparable workload, the runner computes common rates at 50% and 90%
   of the slowest implementation's median measured saturation throughput.
5. Five independent, shuffled latency rounds record every consumer separately,
   followed by JSON/CSV/Markdown/SVG reporting. No best-run selection.

Use `--check-only` for correctness preflight without performance runs. Every
child has a timeout (`--timeout`, default 180 seconds). A timeout, crash,
checksum/order failure or malformed output is retained as an invalid run, not
silently retried or used for a win. `--smoke` results are always unranked.

## Small file map

| File | Responsibility |
|---|---|
| `native.zig` | Shared Zigrupt/Ziggy workload and validation; compile-time library selection |
| `rust/src/main.rs` | Same workload using disruptor-rs's native producer/handler APIs |
| `java/Bench.java` | Same workload using Disruptor, reusable translators and JVM counters |
| `platform.c` | Linux monotonic/process clocks, RSS and verified per-thread affinity; JNI only outside the event hot path |
| `build.py` | Fetch, hash-check and optimized builds; build provenance |
| `run.py` | Locked matrix, core eligibility, independent processes and common rates |
| `report.py` | Conservative comparisons, complete tables and dependency-free SVG |
| `visualize.ipynb` | Reusable, read-only visualization of any reported run directory |
| `notebook-requirements.txt` | Optional JupyterLab and plotting dependencies |
| `tests/test_suite.py` | Matrix/statistics/rejection tests and end-to-end stalled-consumer latency checks |

Generated `.deps/`, `.bin/`, devbox environments and compiler caches are ignored.
Checked-in results contain measurements and provenance, not downloaded source or
executables. `FINDINGS.md` is the human interpretation; generated reports can be
regenerated solely from `manifest.json` and `runs.jsonl`.
