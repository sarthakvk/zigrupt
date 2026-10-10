# Competitive benchmarks

This suite compares Zigrupt's `EventBus` with pinned Java Disruptor and
disruptor-rs sources. `--standalone` runs Zigrupt alone using the same adapter.

## Run

On Linux, from the repository root:

```sh
devbox run bench
devbox run bench --standalone
devbox run bench --case 1p3c 2p1c
devbox run bench --help
```

The command builds missing or stale adapters from sources pinned in `sources.json`
and creates a new directory under `benchmarks/results/` for each run.
`--standalone` builds only Zigrupt and does not fetch the competitors. The suite
covers `1p1c`, `2p1c`, `2p2c`, `4p1c`, `1p3c`, and `3p3c` by default.
Pass `--case` followed by one or more of these names to run only those cases.
Each performance case needs one physical core per producer and consumer, of one type on one
socket; cases exceeding the available cores are skipped. `2p1c` needs three
cores, `2p2c` needs four, and running every case needs six. Use `--check-only`
for correctness checks, or `--smoke` for a short functional run.
The default is five independent repeats with a 3-second warmup and 2-second
measurement target. Pass `--output results/name` to choose a directory within
`benchmarks/`; an existing output directory is rejected. Results are local
measurements, not a universal ranking.

## Output

A full run writes two CSV files in its output directory:

- `throughput.csv`: correctness checks, calibration, blocked cases, and one row
  per saturated throughput repeat. `events_per_second` counts unique events
  delivered to every required consumer; `deliveries_per_second` also counts
  broadcast deliveries.
- `latency.csv`: one row per consumer per repeat, including p50, p99, and p99.9
  in nanoseconds. Failed latency runs have one row with an error and no consumer.

Both files include workload settings, validity, CPU placement, timing, CPU use,
memory use, and available allocation or GC counters. Invalid runs remain in the
CSV. Latency runs use offered rates of 50%, 60%, 70%, 80%, 90%, and 95% of the
slowest selected implementation's median saturated throughput for each workload.
In standalone mode, this is Zigrupt's own median throughput. Latency
is measured from scheduled arrival through the consumer clock read, including
producer backpressure and queueing. The benchmark validates counts, checksums,
order, wraparound, and slow-consumer backpressure before measuring.

Open the single `benchmarks/visualize.ipynb` template to analyze a run. It uses
the optional packages in `notebook-requirements.txt`. Set `DATA_DIR` in its
first code cell to the desired result directory. The notebook shows coverage
and failures alongside throughput, latency, achieved rate, CPU, and memory
plots. It also handles check-only runs without measurement data.

The adapters are `zig/native.zig`, `rust/src/main.rs`, and `java/Bench.java`; `run.py`
coordinates all workloads.
