# Batching performance analysis and review

## Bottom line

- **Single producer, three consumers:** batching is a repeatable win. Limits 4–1024 improve pooled median throughput by **20–32%** over `HEAD~2`; the improvement appears in both shuffled rounds. Limit 64 has the highest pooled median, **14.020 M events/s vs 10.639 M events/s (+31.8%)**. Its separate saturated-latency p99 falls from **13.68 µs to 0.80 µs**.
- **Two producers, two consumers:** no convincing throughput improvement. Pooled changes span **−4.4% to +3.2%**, with substantial overlapping ranges and round-to-round drift. In particular, limit 16's apparent +3.2% is −1.2% in round 1 and +10.1% in round 2. Do not describe it as an established speedup.
- **Single producer, single consumer:** strongly non-monotonic and sometimes unstable. HEAD with limit 1 is already much faster than the old scalar API, so that gain cannot be credited to processing multiple events per callback. Limits 1, 64, and 256 vary widely; their pooled medians are not reliable capacity forecasts. Limit 1024 is comparatively stable at **30.236 M events/s (+27.6%)**, with a separate latency p99 of **2.93 µs**.
- **Recommendation:** retain workload-specific configuration. For a single-producer/multiple-consumer workload, 64 is a useful next tuning candidate, not a proven universal optimum. Do not raise the default globally on this evidence.

No library or benchmark source was changed. No unit tests, batching correctness tests, or test executables were run or added. Review findings below are static observations, not experimentally reproduced correctness bugs.

## Scope and reproducibility

Compared these exact committed trees, including each revision's own benchmark:

- Baseline `HEAD~2`: `34b00f78ff96b41601bf2863ed933d7c5b9d7cd2` — scalar consumption.
- HEAD: `a9589553ab444af756bfc6f44a2f72bb7760346a`.
- Reviewed `ce50100bf0bcf953ccaedeab4d73d595d0053f59` (batch consumption) and `a958955` (drain fix).

Environment: Zig **0.16.0**, native x86-64 **ReleaseFast**, Intel **i5-1135G7**, 4 physical cores / 8 logical CPUs. Governor was `powersave`; frequency was not fixed. No core isolation or background-process termination was performed.

| Topology | Producer CPUs | Consumer CPUs |
|---|---|---|
| 1P/1C | 0 | 1 |
| 1P/3C | 0 | 1,2,3 |
| 2P/2C | 0,1 | 2,3 |

CPUs 0–3 are distinct physical cores. Worker affinity was explicit; their SMT siblings were not assigned benchmark workers. The coordinator parks during timing.

The committed benchmark uses a 1024-slot ring, busy spinning, broadcast delivery, a lightweight per-event countdown, and no per-event clocks in throughput mode. Every consumer receives every event. Throughput means **unique events/s**, not consumer deliveries/s. The new handler still loops over individual events and always acknowledges the full supplied slice; this does not model bulk I/O, expensive application handlers, or partial acknowledgements.

Two shuffled rounds, three independent repetitions per configuration per round: **6 throughput and 6 latency measurements per configuration**, 21 configurations, **126 measurements of each mode**. Configurations were run sequentially, never concurrently. Each mode independently calibrated event counts against a 500 ms target, starting at 100,000 events/producer; pilots and warmups were not reported as repetitions. All reported samples were retained.

Four throughput repetitions and ten latency repetitions finished below the calibration target. Measured throughput durations ranged **229.837–1147.044 ms**; latency durations **467.946–926.364 ms**. The short throughput samples occur in the unstable 1P/1C limits 1 and 256. This is another reason not to overinterpret those configurations. Raw logs disclose every warning.

Builds used `zig build-exe -OReleaseFast --dep zigrupt -Mroot=<snapshot>/bench/ring_buffer.zig -OReleaseFast -Mzigrupt=<snapshot>/src/root.zig -femit-bin=<binary>`. Both modules use ReleaseFast. Exact build commands, revision IDs, binary hashes, topology and run ordering seed are in `manifest.json`; every benchmark invocation is recorded in `runs.jsonl`. `run.py` documents snapshot extraction, builds and shuffled execution. To rerun it, copy the script to a **fresh results directory** so existing snapshots and results are not overwritten.

## Throughput

Median of six measurements, **million unique events/s**:

| Revision / maximum batch | 1P/1C | 1P/3C | 2P/2C |
|---|---:|---:|---:|
| HEAD~2, scalar | 23.701 | 10.639 | 10.195 |
| HEAD, 1 | 93.034 | 10.436 | 9.748 |
| HEAD, 4 | 28.213 | 12.777 | 10.099 |
| HEAD, 16 | 27.473 | 13.086 | 10.518 |
| HEAD, 64 | 80.538 | 14.020 | 10.031 |
| HEAD, 256 | 66.555 | 13.247 | 10.089 |
| HEAD, 1024 | 30.236 | 13.039 | 9.867 |

[Complete table: throughput ranges, deltas and latency](TABLE.md). Machine-readable results: `summary.csv`, `summary.json`; individual measurements and commands: `runs.jsonl`.

### Variability that changes the interpretation

1P/1C observed ranges:

- Baseline: **22.639–24.004 M/s**.
- HEAD, limit 1: **48.439–124.695 M/s**; round medians **101.958 vs 49.140 M/s**.
- HEAD, limit 64: **44.636–119.139 M/s**; round medians **59.385 vs 115.845 M/s**.
- HEAD, limit 256: **42.711–111.383 M/s**.
- HEAD, limit 1024: **29.774–31.347 M/s**.

The unstable limits were faster than baseline in all six main measurements, but the magnitude is not stable, and limit 1 demonstrates that the revision comparison is not a clean measurement of batching amortization alone. It also changes scalar-by-value handling into slice-based handling, including compiler-generated code and object layout. The cause of the large 1P/1C changes was **not established**. Cache/coherence or code-generation explanations remain hypotheses, not findings.

For 1P/3C, limits 4–1024 beat baseline in both rounds; for example, limit 64's round-median gains are **+28.2% and +26.2%**. The pooled +31.8% is a ratio of pooled medians, not the mean of those two percentages. HEAD limit 1 is **−1.9%** against baseline, making this topology much clearer evidence for an actual batching benefit.

For 2P/2C, limit 64 is effectively unchanged against the within-round baseline in both rounds. Small pooled differences should not be mistaken for statistical significance. No confidence intervals or significance claims are made.

## Saturated latency

These are **separate instrumented workloads**, not latency measured at the uninstrumented throughput rates above. Values are medians of each run's p50/p99, not pooled event percentiles. Clock reads and sample writes affect execution. Producers are backpressured; this is not fixed-arrival-rate latency and is subject to coordinated omission.

Selected p50 / p99 results in µs:

| Configuration | Baseline | HEAD, limit 1 | HEAD, limit 64 | HEAD, limit 1024 |
|---|---:|---:|---:|---:|
| 1P/1C | 0.30 / 9.13 | 35.56 / 105.21 | 0.44 / 32.42 | 0.41 / 2.93 |
| 1P/3C | 0.36 / 13.68 | 0.37 / 4.73 | 0.35 / 0.80 | 0.35 / 0.74 |
| 2P/2C | 0.56 / 1.01 | 0.58 / 1.00 | 0.42 / 0.87 | 0.57 / 1.13 |

The 1P/1C limit-1 latency deterioration repeats in both rounds: individual p99s are **100.29–108.69 µs**. Other 1P/1C tails are noisy: baseline p99 ranges **0.59–74.60 µs**, and limit-64 p99 **3.35–35.38 µs**. Avoid inferring a universal tail-latency improvement from a single median.

## Review of the last two commits

Line references below are to repository HEAD.

### 1. Zero-consumption handling needs an explicit liveness policy

`src/ring_buffer.zig:15–20`, `306–307`, `336–337`.

The documented handler contract permits returning 0. Both loops immediately retry the same sequence and republish the unchanged consumer cursor; there is no no-progress wait/backoff path. If a handler remains unable to consume, the running consumer can burn CPU and pin producer capacity; during draining, `stop()` can wait forever in the thread join.

This is a contract/liveness concern, not evidence that the full-consuming benchmark handler hangs. Decide whether nonempty slices require a positive consumed count, or whether zero is supported with defined retry/backoff and shutdown behavior. Merely adding a wait would reduce spinning but would not by itself guarantee drain completion.

### 2. Partial consumption repeats publication scanning

`src/ring_buffer.zig:296–306`, `325–336`.

Each callback is preceded by a fresh acquire-load scan from the current consumer position, even when the previous callback already established that the following slots were published. With a ready batch of B and a handler accepting only one event at a time, repeated calls can do roughly O(B) publication checks per consumed event rather than amortizing the checks across B consumed events. Ring-wrap limits bound each individual scan, but do not remove the repeated work.

This is a performance risk inferred from the code; it was not benchmarked here. The existing benchmark always returns `events.len`, so the measurements do not reveal it. If partial consumption is expected in real handlers, consider retaining the already-verified published endpoint across partial acknowledgements rather than rescanning it.

### 3. The new borrowed-slice contract is underdocumented

`src/ring_buffer.zig:15–20`, `305–307`, `334–337`.

The old callback received a value. The new slice aliases live ring storage. The documentation should explicitly say that returning N acknowledges the **first N elements**, not an arbitrary subset, and that acknowledged elements can be overwritten by producers after return. A handler must copy data it needs to retain; `[]const T` does not make the producer-owned storage immutable forever.

The upper bound on the return value is documented but not enforced. Returning too much violates that contract and can skip events/release unprocessed storage; that is caller misuse, not a demonstrated failure with a conforming handler. A debug assertion could make misuse easier to diagnose without imposing a ReleaseFast check.

### What the drain fix gets right

`a958955` addresses three concrete problems introduced in `ce50100`:

- It limits the slice to the physical end of the ring.
- It treats the producer cursor as an **exclusive** bound (`cursor - c_seq`, not `+ 1`).
- It verifies publication of each subsequent slot rather than assuming all claimed sequences are published; this matters for multi-producer holes.

The resulting running/draining batch scans use acquire loads and only supply a contiguous published prefix. This is a static assessment, not a correctness-test result. The original Disruptor also checks contiguous publication for multiple producers and advances consumer progress at batch boundaries.

The latest commit changes only draining. The benchmark timestamps completion inside the last handler and performs shutdown afterward; it does **not** measure drain throughput or shutdown latency. Therefore the headline performance results mostly characterize `ce50100`'s running-path and callback changes, not the speed of the drain fix.

### Why increasing the limit need not improve performance

The limit is a ceiling, not a target fill size. A batch stops at the first publication gap or physical ring boundary, and the consumer never waits to fill the batch. Actual batch-length distributions were not collected. Larger limits therefore do not prove larger actual batches.

The implementation still acquire-loads publication metadata for every delivered event. It mainly amortizes handler dispatch, consumer-sequence publication and outer-loop bookkeeping; it does not remove producer claim/publication work. It also delays releasing consumed capacity until the handler returns. These facts explain why workload-dependent outcomes are plausible, but do not establish the cause of any particular timing change.

## Supplementary profiling

After the complete benchmark matrix finished, three separate `perf record -e cycles:u -F 499` runs sampled 1P/1C baseline, HEAD limit 1 and HEAD limit 64. Commands are in `profile-commands.json`; recordings, symbol/source reports and logs are retained as `profile-*`. They are **excluded from all headline statistics**.

These recordings cover the entire benchmark process, including pilots, idle spinning, latency instrumentation and percentile sorting. They do not isolate a measured throughput phase, so whole-process cycle percentages must not be presented as per-event hot-path costs. Profiled HEAD throughput medians were **152.275 M/s (limit 1)** and **159.888 M/s (limit 64)**, outside the main-run ranges, reinforcing that absolute 1P/1C rates are sensitive to execution conditions. Profiling did not establish the cause; no causal performance claim is made from those samples.

## Verification and limits

- Both committed benchmark executables built successfully.
- All 42 main invocations exited successfully and produced exactly three throughput and three latency measurements; result accounting verified all 21 configurations have six measurements per mode.
- `git diff --check HEAD~2 HEAD` reported no whitespace errors.
- Repository status was clean before and after the analysis; only ignored files in this new results directory were created.
- No tests were run or added. Normal benchmark timing/countdown and latency-sample checks remained enabled and unchanged.
- Not measured: actual batch-size distributions, partial-consumption workloads, zero-progress behavior, larger/smaller rings, expensive handlers, more than four active workers, fixed-arrival-rate latency, shutdown/drain performance, or architectures other than this machine.
