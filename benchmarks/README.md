# Competitive benchmarks

This suite compares Zigrupt's `EventBus` with pinned Java Disruptor and
disruptor-rs sources. `--standalone` runs Zigrupt alone using the same adapter.

## Run

On Linux, from the repository root:

```sh
devbox run bench
devbox run bench --standalone
devbox run bench --help
```

The command builds missing or stale adapters from sources pinned in `sources.json`
and creates a new directory under `benchmarks/results/` for each run.
`--standalone` builds only Zigrupt and does not fetch the competitors. A full
performance run needs six physical cores of one type on one socket. Use
`--check-only` for correctness checks, or `--smoke` for a short functional run.
The default is five independent repeats with a 3-second warmup and 2-second
measurement target. Pass `--output results/name` to choose a directory within
`benchmarks/`; an existing output directory is rejected. Results are local
measurements, not a universal ranking.

## Output

A full run writes two files in its output directory:

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

The adapters are `zig/native.zig`, `rust/src/main.rs`, and `java/Bench.java`; `run.py`
coordinates all workloads. `visualize.ipynb` is left for a later update to the
CSV format.
