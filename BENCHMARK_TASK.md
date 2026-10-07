# Task: Establish Zigrupt’s competitive performance baseline

## Research and selected competitors

Use these **three external projects**:

| Project | Pinned baseline | Why it belongs |
|---|---|---|
| [LMAX Disruptor — Java](https://github.com/LMAX-Exchange/disruptor/releases/tag/4.0.0) | `4.0.0` | The original implementation and primary target to beat. Supports preallocated events, multiple producers, and broadcast consumers. |
| [disruptor-rs — Rust](https://github.com/nicholassm/disruptor-rs/tree/v4.4.0) | `4.4.0` | A native-code competitor with the same Disruptor model, single/multi-producer support, busy spinning, and batching. Separates competition with the design from competition with the JVM. |
| [Ziggy — Zig](https://github.com/nubskr/ziggy/tree/7c6c1cd7235f9315edc81f16a4ba7c2f061f2ba4) | Commit `7c6c1cd7235f9315edc81f16a4ba7c2f061f2ba4` | A relevant same-language bounded-channel baseline. |

**Important distinction:** Ziggy distributes events among consumers; Disruptor broadcasts every event to every consumer. Their multi-consumer benchmarks would measure different work. This distinction is explicit in [LMAX’s documentation](https://lmax-exchange.github.io/disruptor/user-guide/index.html) and visible in [Ziggy’s implementation](https://github.com/nubskr/ziggy/blob/7c6c1cd7235f9315edc81f16a4ba7c2f061f2ba4/src/ring_buffer.zig).

Published benchmark numbers are not comparable across these projects: hardware, batching, workloads, and latency definitions differ. Rerun all competitors under one specification.

## Objective

Build a reproducible benchmark suite and report comparing Zigrupt against the three pinned competitors above. Identify where Zigrupt wins, loses, or trades throughput for latency.

**Zigrupt target:** benchmark the current `EventBus` implementation in `src/ring_buffer.zig`, not the older `Disruptor` implementation currently used by `test/benchmark.zig`.

## Locked workload scope

In-process, bounded, lossless inter-thread messaging with backpressure.

| Topology | Semantics | Competitors |
|---|---|---|
| 1 producer → 1 consumer | Every event consumed once | All four |
| 4 producers → 1 consumer | Every event consumed once | All four |
| 1 producer → 3 consumers | Every consumer receives every event | Zigrupt, Java Disruptor, disruptor-rs |
| 3 producers → 3 consumers | Every consumer receives every event | Zigrupt, Java Disruptor, disruptor-rs |

For each topology:

- Capacities: **2,048 and 32,768 events**.
- Application payloads: **8 and 64 bytes**, with identical contents and equivalent consumer checksum work.
- One event published per API call. Preserve and document native internal consumer batching; do not artificially disable competitor optimizations.
- Use the appropriate single- or multi-producer implementation.

**Excluded:** work-sharing multi-consumer queues, broadcast adapters for Ziggy, dependency pipelines, networking, persistence, explicit batch-publication experiments, and performance optimizations to Zigrupt itself.

## Required measurements

1. **Saturated throughput:** unique published events/second, measured through completion by every required consumer—not merely publication. Report consumer deliveries/second separately for broadcast.
2. **End-to-end latency:** p50, p99, and p99.9 at common offered rates of **50% and 90% of the slowest implementation’s measured saturation throughput**, determined separately for each comparable workload.
3. **Resource cost:** CPU consumption, peak resident memory, and allocations/GC activity where applicable.

Latency must include producer backpressure and queueing through handler completion. Use scheduled arrivals without silently resetting the schedule after stalls, avoiding coordinated omission. For broadcast, report each consumer separately and highlight the worst consumer.

Keep throughput and latency measurements separate so timestamping does not distort the throughput headline.

## Fair-comparison requirements

- Same machine, OS, physical-core placement, and resource budget; avoid worker oversubscription and mixing different core classes.
- Optimized native builds; warmed-up JVM with pinned JDK and recorded JVM/GC settings. Exclude startup, thread creation, and initialization from steady-state measurements.
- Preallocate events and measurement storage; avoid harness-induced per-event allocation.
- Use busy-spin consumers where supported; use Ziggy’s polling API. Preserve and disclose built-in producer backoff differences rather than modifying competitors.
- Record toolchain versions, commits, build options, and actual memory footprints. Equal event capacity does not imply equal memory usage.
- Use repeated independent runs, varied execution order, and report variability—not best-run numbers.
- Validate loss, duplication, ordering guarantees, wraparound, and backpressure, including a slow-consumer correctness case. Invalid runs cannot produce ranked results.

## Deliverables and completion criteria

- Benchmark adapters, a shared workload specification, and concise reproduction instructions.
- Machine-readable results and a comparison report containing throughput, latency, resource costs, and Zigrupt/competitor ratios.
- Explicit wins, losses, and inconclusive results for each workload. Claim a win only beyond measurement variability; label throughput/latency tradeoffs rather than declaring an overall winner.
- Ranked follow-up optimization opportunities supported by measurements.

**The ambition is to beat all three on applicable workloads. Completing this task means establishing trustworthy results, not manufacturing a win.**

Research completed; no benchmarks have been run.
