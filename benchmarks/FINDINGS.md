# Findings: historical EventBus baseline (2026-10-07)

**Not a measurement of current `origin/main`.** This preserved baseline predates
the cached sequencers, specialized single-producer path and batch-consumption
API. The observations and follow-up hypotheses below refer only to the source
snapshot in `results/baseline/manifest.json`. The current adapter enables native
consumer batching up to ring capacity; fresh runs are required to assess it.

**Zigrupt does not beat these competitors on saturated throughput in this run.**
Of 20 applicable measured Zigrupt/competitor comparisons, **16 are losses, four
are inconclusive, and none is a throughput win**. There is one narrowly scoped
latency win, described below; it is a throughput/latency tradeoff, not an overall win.

[Complete report](results/baseline/REPORT.md) · [Raw runs](results/baseline/runs.jsonl)
· [Machine/toolchains](results/baseline/manifest.json) · [Specification](SPEC.md)

## What was completed, and what remains blocked

The final run on **2026-10-07**, Intel **i5-1135G7**, Linux, used physical cores
0–3, the `powersave` governor, and five independent processes per measured cell.
It contains:

- **56 passing correctness preflights**, including all four topologies, both
  capacities/payloads, repeated wraps, exact broadcast traces and slow-consumer
  backpressure. Oversubscribed correctness runs are not performance results.
- **140 throughput samples** and **280 latency samples**, all delivery-valid.
- **28 discarded calibration samples**, plus explicit exclusions for 28
  implementation/workload combinations requiring more physical cores.
- Per-consumer p50/p99/p99.9, completed unique events and deliveries, CPU, RSS,
  allocation/GC evidence, source/build provenance, JSON/CSV and an SVG plot.

**The full performance matrix is not complete:** 4→1 needs five physical cores;
3→3 needs six. This host has only four. Their adapters passed correctness checks,
but throughput/latency rankings must be collected on a suitable host. The suite
will run them automatically there; no SMT substitution or Ziggy broadcast adapter
was used to fill those gaps.

The remaining measured comparisons also have real uncertainty. Six Java cells
(three throughput, three 50%-load latency) recorded compilation activity despite
warmup and are deliberately unranked. These need longer/more representative JVM
warmup before drawing conclusions. No data was silently retried or cherry-picked.

## Throughput: a substantial gap, not a near tie

Selected **median** completed unique-event rates, millions/second:

| Workload | Zigrupt | Java | Rust | Ziggy |
|---|---:|---:|---:|---:|
| 1→1, 2,048, 8 B | 9.686 | 48.585 | 113.196 | 39.205 |
| 1→1, 2,048, 64 B | 10.530 | 31.380 | 84.052 | 21.743 |
| 1→1, 32,768, 8 B | 10.072 | 70.335 | 115.969 | 58.648 |
| 1→3, 2,048, 64 B | 5.407 | 11.068 | 7.434 | not comparable |

For example, the 1→1 / 32,768 / 8 B Zigrupt ratios are **0.143× Java,
0.087× Rust, and 0.172× Ziggy**; all three are range-separated losses.
Zigrupt's 1→1 medians stay around 9.46–10.53 M events/s across capacities/payloads.
The larger ring does not close its throughput gap.

The 1→3 / 32,768 / 64 B comparison with Rust is **inconclusive**, despite a
0.519× median ratio: Zigrupt's 5.962–6.555 M/s range overlaps Rust's
6.532–14.230 M/s range. The other three inconclusive throughput comparisons are
Java cells excluded for recorded JIT activity. The full report includes every
workload and its exact range, not just these selected medians.

## Latency: one observed win, much worse headroom at 90%

At **1→3 / 2,048 / 64 B**, offered load **2,703,501 events/s (50%)**, the worst
consumer's p99.9 across independent runs is:

| Implementation | Median p99.9 | Min–max |
|---|---:|---:|
| Zigrupt | **7.111 µs** | **5.943–7.255 µs** |
| Java | 7.951 µs | 7.671–12.047 µs |
| Rust | 5.479 µs | 4.943–5.935 µs |

Zigrupt's p99.9 is **0.894× Java's**, with non-overlapping observed ranges and no
recorded compilation/GC in these samples. However, its throughput is **0.489×
Java's** on the same workload, and its p99 is indistinguishable from Java's.
This is the suite's one observed latency win, and explicitly a **tradeoff**.
Confirm it with longer runs; five short laptop samples are not a universal claim.

At 90%, Zigrupt loses both p99 and p99.9 to Rust in **all eight measured workloads**.
For the broadcast 64-byte cases:

| Capacity | Offered events/s | Zigrupt p99 | Rust p99 | Java p99 |
|---:|---:|---:|---:|---:|
| 2,048 | 4,866,303 | 28.574 ms | 5.679 µs | 240.639 µs |
| 32,768 | 5,553,411 | 109.576 ms | 77.695 µs | 6.335 µs |

These are medians of the **worst consumer per run**, not pooled consumer histograms.
The 32,768 / 64 B Zigrupt latency run achieves only **about 90.0% of its offered
rate**, after draining, and its median p99.9 is 111.018 ms. This is a
**finite-window overload result**, not a stationary latency SLA. Timestamping,
pacing, histogram work and host scheduling reduce the headroom available in the
separate latency workload. The deadline schedule is never reset to hide that lag.
The 2,048 case achieves about 97.5% of its offered rate and also accumulates lag.

Some Java 50%-load p99.9 values look much worse than Zigrupt's, but their samples
recorded JIT activity; those apparent wins are **not claimed**. Many other tail
comparisons overlap substantially. See the per-consumer ranges before using any
single median for a decision.

## Resource costs

- Native throughput uses approximately **two CPU cores** for 1→1 and **four** for
  1→3. Java 1→1 throughput uses roughly 1.66–1.91 cores at these settings, while
  achieving higher event rates. Busy-spin latency runs generally use the full
  worker budget even at 50% offered load.
- At 1→1 / 32,768 / 8 B, median peak RSS is **3.523 MiB Zigrupt**, **2.613 MiB Rust**,
  **6.297 MiB Ziggy**, and **313.355 MiB Java**. These are executable footprints,
  not isolated library allocations. Java's fixed, pre-touched 256 MiB heap is a
  major part of its footprint; this does **not** establish its minimum heap need.
- The same case requests **524,560 bytes** through Zigrupt's bus allocator versus
  **4,194,304 bytes** through Ziggy's. Ziggy's per-slot 128-byte alignment explains
  that requested-storage difference. Equal event capacities are not equal memory
  budgets. Rust's reported allocator-live bytes have a different scope.
- All **300 measured native samples** report zero allocation calls within the
  instrumented allocator scope. Java reports zero worker allocated bytes in
  105/120 measured samples; the other 15 report **72 bytes per entire sample**,
  coinciding with recorded compilation activity. This is not per-event allocation.
  Its cause was not isolated. **All 120 measured Java samples report zero GC collections.**
- Latency histograms add **512 KiB per consumer**, allocated/touched before warmup.
  CPU/RSS and allocation counter scopes are documented, not conflated.

An initial measurement attempt exposed `getrusage` retaining pre-`exec` launcher
RSS. That attempt was stopped and excluded. A regression test demonstrated the
failure with a 64 MiB launcher allocation; the final run uses `/proc/self/status`
`VmHWM` and was collected afresh after the fix. No initial-attempt samples were
mixed into this baseline.

## Ranked follow-up experiments — not changes made here

These are **measurement-supported priorities and source-based hypotheses**, not
causally proven fixes. Change one mechanism at a time and rerun both throughput
and scheduled-arrival latency; retain all correctness gates.

1. **Reduce gating-sequence traffic with a cached safe publication boundary.**
   Zigrupt checks the consumer sequences for each publication. The pinned Rust
   producer caches how far it can publish before checking consumers again.
   The 1→1 / 32,768 / 8 B gap is 10.072 vs 115.969 M/s, despite both being native,
   preallocated implementations with the same handler work. First profile/cache-
   traffic counters, then test caching alone. Preserve slow-consumer and wrap safety.

2. **Test native internal consumer batching of sequence acknowledgements.**
   Zigrupt releases a consumer sequence per event; Java and Rust already amortize
   acknowledgements over available batches. Zigrupt falls from 10.072 to 5.158 M/s
   when broadcasting the 32,768 / 8 B workload, and its high-load tails are poor.
   Measure acknowledgement/coherence cost before changing it. Any batching must
   retain losslessness, publication-gap ordering and handler-completion latency;
   do not change to batch-publication APIs or weaken competitor optimizations.

3. **Specialize the single-producer claim path, then recheck latency headroom.**
   The current single-producer method performs an atomic `fetchAdd` per event.
   Its nearly flat 1→1 throughput across the four payload/capacity settings suggests
   investigating fixed synchronization cost before allocator tuning. Confirm the
   instruction/cycle cost rather than assuming it explains the whole gap. A
   single-writer optimization must preserve lifecycle visibility and stop/drain
   correctness. MP behavior has not been performance-measured on this host.

Before treating any proposed optimization as successful, repeat on an idle,
thermally stable **≥6-physical-core** machine with longer samples and JVM warmup
that eliminates the recorded compilation cases. Measure instrumented latency
headroom as an additional diagnostic, but retain the specified common 50%/90%
rates for comparison. Allocation tuning is not a leading priority given the
observed zero native steady-state allocation calls.
