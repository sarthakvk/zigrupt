---
title: Performance and benchmarking
description: Tune capacity and batching, then measure with the repository benchmark.
---

Measure with representative handlers and payloads before drawing conclusions
about performance. Fixed ring storage does not eliminate allocation or I/O in
handlers. Busy spinning can occupy cores while idle, while yielding changes
scheduling costs. More producer threads can increase contention. No strategy
or configuration is fastest for every workload.

Capacity provides room for bursts but cannot remedy sustained consumer lag.
Larger batch limits can reduce callback frequency, but may increase the work
done before a handler acknowledges progress. The benchmark uses capacity 1,024
and accepts `--max_batch=1` through `--max_batch=1024` (default 1):

```sh
zig build bench -- --publishers=2 --consumers=2 --max_batch=8
```

Interpret benchmark results in the context of the reported workload, hardware,
and toolchain. They do not guarantee reliability or latency in an application.

<!-- include: bench/README.md -->
```sh
zig build bench -- --publishers=1 --consumers=1
# Linux: choose logical CPUs allowed by your affinity mask, ideally separate physical cores.
zig build bench -- --publishers=2 --consumers=2 --publisher_cpus=2,4 --consumer_cpus=6,8
zig build test-bench
```

The benchmark uses ReleaseFast, capacity 1,024, busy-spinning producers and
consumers, and broadcast semantics: every consumer receives every event.
Use `--max_batch=1` through `--max_batch=1024` to set the consumer batch limit
(default 1). Keep this setting consistent when comparing runs unless batch size
is the variable being measured.

## Repetition and duration

Defaults: `--events_per_publisher=100000 --repetitions=5 --min_duration_ms=500`.
The event count is a **minimum**, not an exact count. Each mode doubles it in
pilot runs until one measured phase reaches the duration target. Pilot results
are discarded, and every reported repetition uses the same calibrated count.
Runs shorter than the target are retained and flagged, not silently filtered.
At least two repetitions are required.

Each pilot and repetition creates a fresh bus and workers, then warms up with
up to 100,000 events per producer. Allocation, startup, warmup, joins, shutdown,
and percentile sorting are outside the measured phase. A consumer-local
countdown tracks deliveries; each consumer acknowledges completion only once.
The last consumer timestamps completion **before** waking the parked coordinator,
so scheduler wakeup latency is not included. Timing starts just before releasing
ready producers and includes their start response and final-handler bookkeeping;
this is not an isolated ring-buffer operation benchmark.

Throughput reports unique published events/second through completion by all
consumers. The headline is the median of independent runs, with the observed
minimum and maximum (not a confidence interval). Latency reports each run's
p50/p99 and the median/range of those percentiles; samples are not pooled across
runs. Modes run separately, throughput first; thermal/frequency drift and other
machine activity can still affect comparisons.

## Placement

`--publisher_cpus=` and `--consumer_cpus=` take comma-separated logical CPU IDs,
one per corresponding worker, in worker-index order. Each list is optional.
Explicit affinity is supported on Linux only. IDs are checked against the
coordinator's inherited affinity mask; pinning failures abort the run. Consumers
are identified through an untimed discovery delivery, pinned, and then warmed
up. Producers pin themselves before announcing readiness.

The benchmark prints the requested mapping, warns about unpinned workers,
duplicate CPU assignments, and worker counts exceeding the available logical
CPU count. It does not automatically choose cores. Distinct logical CPUs can
share a physical SMT core, and unpinned workers may compete with pinned ones.
Choose placement using your machine's topology; avoid oversubscription and
background load. The coordinator remains unpinned but parks during measurement.

## Latency and instrumentation limits

Latency is measured from immediately before `produce()` to the consumer's clock
read near handler entry. It includes backpressure and queueing, but not the
subsequent sample write or complete handler work. This is **saturated latency**:
producers slow down when blocked. It is not fixed-arrival-rate latency and does
not correct for coordinated omission.

Clock reads and sample writes still perturb execution. Samples occupy separate,
cache-line-aligned regions per consumer to prevent cross-consumer false sharing.
Storage is initialized before timing; padding is excluded from percentiles.
Throughput handlers do not read clocks per event or write latency samples, but
still perform countdown bookkeeping. No estimated overhead is subtracted.

Duration calibration is independent for latency so storage is not sized from
uninstrumented throughput. Storage nevertheless grows with calibrated event
count times consumer count, using `@sizeOf(i96)` bytes per sample plus padding;
the allocated byte count is printed. Lower `--min_duration_ms` if memory is
limited. A quick functional check (not meaningful performance data) is:

```sh
zig build bench -- --events_per_publisher=1000 --repetitions=2 --min_duration_ms=1
```
<!-- end:bench/README.md -->
