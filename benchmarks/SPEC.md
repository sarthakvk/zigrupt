# Shared workload and measurement contract

## Scope and pins

Linux in-process, bounded, lossless messaging with backpressure. No networking,
persistence, dependency pipelines, explicit batch publication, or production
optimizations. Exact competitor commits and checked source-tree hashes are in
`sources.json`; Zigrupt's commit **and actual `src/` hash** are in each manifest.

| Producers | Consumers | Meaning | Implementations |
|---:|---:|---|---|
| 1 | 1 | One delivery per event | All four |
| 4 | 1 | One delivery per event | All four |
| 1 | 3 | Every consumer receives every event | Zigrupt, Java, Rust |
| 3 | 3 | Every consumer receives every event | Zigrupt, Java, Rust |

Every row crosses capacities **2,048 / 32,768** and application payloads
**8 / 64 bytes**. Ziggy is a work-sharing channel, not a broadcast bus: it is
never adapted into the broadcast comparisons. It exposes one MPMC implementation,
used even for 1→1. The other three select their native single-/multi-producer paths.

## Event contents and equivalent work

An event is one or eight unsigned 64-bit words: `word[j] = id + j`. Warmup IDs
are `0..warm-1`; measured IDs are `warm..warm+count-1`. Producer `p` emits IDs
congruent to `p mod producer_count`, increasing by `producer_count`. Both phase
counts are multiples of the producer count, so streams remain contiguous.

Every handler, on **every** warmup and measured delivery:

1. Checks the next expected ID for that producer; this detects loss, duplication
   and per-producer reordering without a per-event allocation or a giant bitmap.
2. Adds every payload word to an unsigned wrapping checksum.
3. Updates `order_hash = order_hash * 31 + id`, wrapping at 64 bits.
4. In latency mode, records a completion latency in its own preallocated histogram.
5. In correctness mode only, stores the full ID trace for exact broadcast comparison.

At completion every consumer must have received `N = warm + count` events and
have checksum

```
words * N * (N - 1) / 2 + N * words * (words - 1) / 2   (mod 2^64)
```

All broadcast hashes must agree; correctness traces must match byte for byte.
The Python runner independently checks the counts, checksum, broadcast hashes,
number of consumers and latency sample counts. This validation work is part of
the application workload in **all** adapters, not removed from headline timing.
Checksums/hashes alone cannot exclude every theoretical compensating corruption;
preflight adds exact traces and controlled backpressure.

No measurement timestamps enlarge the application payload. The ID identifies a
scheduled arrival analytically. Java stores the payload in a preallocated `long[]`
owned by each preallocated event; native implementations store inline arrays.
Object/array headers and library metadata are not application payload, but do
contribute to the reported real process footprint.

## Publication, batching and waiting

Exactly one event is published per call:

- Zigrupt `EventBus.produce(event)`; no use of the old Disruptor benchmark.
- Ziggy `RingBuffer.produce(event)` and `tryConsume()` polling.
- Rust `Producer.publish(closure)`; no `batch_publish`.
- Java `RingBuffer.publishEvent(translator)` with one reusable, producer-local
  translator. No per-event lambda object, boxed ID, or temporary event.

Native behavior is preserved, not normalized away:

| Implementation | Consumer behavior | Producer backpressure |
|---|---|---|
| Zigrupt | BusySpin; publication test and consumer-sequence release per event | BusySpin; checks all gating consumers |
| Java | BusySpinWaitStrategy (`Thread.onSpinWait`); native BatchEventProcessor batches available events and releases its sequence per batch | Native sequencers use `LockSupport.parkNanos(1)` when full; actual OS parking can be much longer |
| Rust | BusySpin (empty wait); native handler loop batches available events and releases its cursor per batch | Native tight retry loop; cached consumer progress |
| Ziggy | `tryConsume()` with a spin hint on empty; one dequeue per call | Native hints and yield after 256 slot-mismatch spins; CAS retries preserved |

Sources: the pinned `src/ring_buffer.zig`; Java `BatchEventProcessor.java`,
`SingleProducerSequencer.java`, `MultiProducerSequencer.java`,
`BusySpinWaitStrategy.java`; Rust `consumer.rs`, `producer/single.rs`,
`producer/multi.rs`, `wait_strategies.rs`; Ziggy `src/ring_buffer.zig`.
No explicit batch-size cap or artificial sequence flush is added.

## Lifecycle and timing

One independent process produces one reported sample. Ring contents, handlers,
histograms and optional correctness traces are preallocated. Consumer threads
and producer handles/threads exist before warmup. Each worker verifies its
single-CPU affinity; consumers pin on their first **warmup** event, never on their
first measured event. Producer/consumer IDs have identical placement across
implementations for a given topology.

Workers reuse the **same ring and threads** for warmup and measurement. The
controller sleeps while waiting for phase completion; it is not a busy-spinning
extra worker. It waits for every producer and every consumer before opening the
next phase. Histograms are zeroed at the warmup boundary. Producers wait after
publication, so thread teardown is outside the measured interval.

The controller records `cpu_start`, records monotonic `T0`, then release-opens the
measured gate. Each consumer records its completion clock **after** validating,
checksumming and (where enabled) histogramming its last event. The maximum of
these completion timestamps is `T1`. Joining, destruction, percentile extraction,
JSON formatting and process exit are outside the timing boundary.

```
unique_events_per_second = count / ((T1 - T0) / 1e9)
deliveries_per_second    = unique_events_per_second * consumers
```

This includes the gate handoff and draining to the last handler, not just the
publication loop. The endpoint is application-handler work completion, just
before its completion flag/return; library acknowledgement of the last sequence
is not separately timed.

Throughput mode performs **no per-event clock reads or histogram updates**.
Boundary clocks and common correctness work remain. Calibration is discarded,
then sets event counts to target the requested warmup/measurement durations.
Actual elapsed durations are retained; counts and achieved durations can differ
as CPU frequency/contention changes. Warmup and sampling are independent of
process startup and initialization.

### JVM warmup

The JVM uses the pinned JDK, 256 MiB fixed/pre-touched heap, Serial GC,
`-XX:-TieredCompilation -Xbatch -XX:CICompilerCount=2`, and an active-processor
count equal to the worker budget. The full flags and actual `java -version` output
are recorded (Nix's package label and reported JVM build suffix need not match).

Before the main warmup, two discarded instances exercise **both phases and their
boundaries**, each with `max(100000, 4 * capacity)` events per phase, rounded to a
producer multiple. This warms phase transitions as well as the event loop. Each
instance is stopped/joined before the next. The actual sample then performs its
own calibrated warmup on its own reused ring/threads. Allocation, GC and JIT
management counters are initialized before warmup. Measured compilation activity
is reported; a group containing such a sample is not used to claim a win/loss.

## Coordinated-omission-free latency

For each workload, use each implementation's median **valid saturation
throughput**, then take the minimum. Offered rates are the floor of **50% / 90%**
of that minimum. Every applicable implementation uses exactly the same rate for
that workload/load level. If any implementation lacks a complete set of valid
throughput repeats, common-rate latency for the workload is not scheduled.
`rates.json` records the derivation; each raw sample also records its integer rate.

For measured event offset `g = id - warm`:

```
scheduled_arrival(g) = T0 + floor(g * 1_000_000_000 / offered_rate)
latency(g, consumer) = handler_completion_clock - scheduled_arrival(g)
```

Each producer waits for its assigned scheduled arrival **before** calling the
publication API. If it is late or blocked in publication, later arrivals retain
their original deadlines: no resetting to "now", dropping missed arrivals,
limited-outstanding-window throttle, timestamp-at-successful-publish, or sampled
subset. Generation delay, producer backpressure and queueing are therefore all
included. Multi-producer global arrival order need not equal actual publication
order; each producer's order and the broadcast publication order must hold.

The same schedule and histogram path are exercised during latency warmup.
Latency mode is separate from throughput because clock reads, pacing and
histogram writes cost time. If an implementation cannot sustain the offered rate
with instrumentation, backlog is allowed to grow; the resulting high latency is
not hidden or discarded. `events_per_second` shows its achieved completion rate.

Each consumer owns 65,536 preallocated 64-bit histogram counters (512 KiB):

```
shift  = max(0, bit_length(max(latency_ns, 1)) - 10)
bucket = shift * 1024 + (latency_ns >> shift)
```

Percentiles use nearest-rank `ceil(n * quantile)` and report the bucket's upper
bound. Bins are exact below 1,024 ns; above that their relative width is at most
1/512 (about 0.2%). The range comfortably covers the process timeout. All events
are counted; p50, p99 and p99.9 are reported per consumer. Worst-consumer values
are maxima **per independent run**, then summarized across runs, not a pooled
histogram that could hide a slow consumer. The latency clock is read after all
application checksum/order/hash work, immediately before recording that sample;
it cannot include its own histogram update. That instrumentation still delays
subsequent handlers. Quantization is much smaller than the observed host jitter,
but nanosecond-scale differences should not be overinterpreted.

## Correctness preflight

All 56 applicable combinations run before ranking, even on a host too small for
some performance topologies. These correctness-only processes may share physical
cores (and are explicitly excluded from performance summaries).

Preflight uses four ring capacities of warmup events and eight capacities of
measured events, rounded to a producer multiple. This exercises wraparound at
both required capacities and both payload sizes. The **last consumer** is gated
inside its first measured handler while the other consumers continue. Once it
has entered, the controller waits 50 one-millisecond sleeps, records completed
publication calls, waits another 20 sleeps, and verifies:

- publication progress is stable with at least one attempted but incomplete call;
- precisely `capacity` events have published while the slow handler is held;
- for Ziggy only, the count is `capacity + 1`, because `tryConsume()` releases the
  ring slot before the copied event is handled;
- releasing the slow consumer lets all producers and consumers finish with exact
  per-producer ordering, complete counts/checksums and matching broadcast traces.

No artificial delay appears in ranked runs. Separate adapter tests enable the
same stall in **latency mode** and require a visible >20 ms p99 tail at the slow
consumer, verifying that backpressure is included rather than resetting the schedule.
Crashes/timeouts/validation failures are retained as invalid, and cannot produce
ranked results. These tests do not attempt to prove arbitrary sequence-counter
integer overflow; "wraparound" here means repeated ring-slot reuse.

## Resource accounting and placement

- **CPU:** process CPU nanoseconds (all its threads) between the start snapshot and
  the latest consumer CPU snapshot, divided by completion wall time. Includes
  publication, spinning, pacing, the small sleeping controller overhead, and JVM
  activity during the window; excludes initialization, warmup, sorting and teardown.
- **Peak RSS:** Linux `/proc/self/status` `VmHWM * 1024`, read before teardown.
  The current executable's address-space high-water mark, including its startup,
  pre-touch and warmup; not ring bytes or steady-state live memory. Unlike
  `getrusage.ru_maxrss`, this excludes the launcher's memory inherited by `fork`
  before `exec`. A regression test inflates the launcher by 64 MiB to verify this.
  It can retain the footprint of earlier JVM prewarm instances. Equal capacities
  do not imply equal RSS or allocated bytes.
- **Zig:** requested bytes/calls through the allocator supplied to the bus, including
  any bus-owned thread setup allocations; event-loop delta calls. Measurement
  arrays are allocated separately before warmup, not per event. The count does
  not claim to intercept every libc allocation or page mapping.
- **Rust:** global allocator call delta and live requested bytes immediately before
  measurement. Includes Rust harness/library allocations, not all libc/thread-stack
  mappings. No GC.
- **Java:** per-worker ThreadMXBean allocated-byte delta, process GC count/time
  deltas, compilation-time delta, and pre-window heap-used bytes. This is not total
  JVM/native allocated memory. The main thread's counter-query allocations are
  excluded from worker bytes; process RSS includes the JVM as a whole.
- Measurement histogram byte counts are reported explicitly. Correctness traces
  are not allocated in ranked runs.

The runner selects one logical CPU per physical core from the largest same-socket,
same-core-type/capacity group exposed by Linux sysfs. Every process, including JVM
helper threads, is restricted to the selected workload CPU set; each worker pins
to a distinct member. SMT siblings are never assigned to two ranked workers.
On heterogeneous machines, confirm that sysfs exposes the core classes correctly
before using the automatic selection. CPU frequency governors/topology and load
averages are recorded; SMT, turbo, governors, IRQ placement and OS isolation are
not changed. Other host activity and shared thermal/power limits remain sources
of uncertainty.

## Repetition and decisions

Seeded shuffling varies implementation/workload order in **every** round. Every
sample uses a fresh process. No best-run selection or silent retries. Comparisons
require the configured number of valid repeats (at least three), each with at
least 0.5 s actual warmup and measurement and no measured JVM compilation activity.
Smoke mode is never ranked. Invalid/preflight-failing/blocked cells are explicit.

Tables report median, minimum and maximum; JSON/CSV additionally report sample
count and coefficient of variation. Zigrupt wins/loses only when the entire
observed range is on the favorable/unfavorable side of the competitor's range.
Overlapping ranges are **inconclusive**. This conservative descriptive rule is
not a confidence interval, significance test, or claim about unseen workloads.
Throughput and latency ratios have separate directions; opposite outcomes are
called **tradeoffs**, never rolled into an overall score.

## Adapter protocol

The runner passes numeric positional arguments:

```
producers consumers capacity payload_bytes warm_events measured_events rate check cpu0 cpu1 ...
```

`rate=0` means saturated throughput; `check=1` enables the gated slow-consumer and
exact-trace checks. The CPU list orders producers first, then consumers. The
runner supplies only the locked, validated matrix and positive producer-divisible
counts; these low-level executables are not general-purpose command-line APIs.
Successful adapters emit one JSON object on stdout. Assertions fail the process;
the controller retains failure information and enforces a timeout.
