# Behavior checklist

Reviewed against `src/root.zig`, `src/ring_buffer.zig`,
`src/waiting_strategy.zig`, and the existing tests on this branch. Baseline:
Zig 0.16.0, package 0.0.1, 28/28 existing tests passing. This is an evidence
map for maintaining the documentation as main evolves, not a frozen scope.

No library source or tests are changed by this documentation task. Where a
rule follows from source or application ownership rather than a dedicated
test, that distinction is explicit below.

| Reviewed contract | Evidence | Documentation consequence |
| --- | --- | --- |
| Event type, producer mode, handler list, and strategy types determine the bus type; allocator/capacity/batch size are runtime inputs | `RingBufferEventBus` and `init` in `src/ring_buffer.zig` (source) | Configuration/reference separates the two stages |
| Each registered handler receives the stream in the same sequence order; handlers run independently | `test/ring_buffer_single_producer.zig`: order across wraps; `test/ring_buffer_multi_producer.zig`: concurrent producers deliver exactly once | Describe broadcast, not a competing work queue; do not promise identical batch boundaries |
| Sequential calls within a producer retain order; cross-producer interleaving is unspecified; publication gaps are not skipped | Multi-producer delivery and unpublished-claim tests | Do not equate claim order with wall-clock completion order |
| One thread per handler; a handler's calls are serial | `start` and `handleEvent` (source) | Different handlers may run concurrently, including duplicate function registrations |
| Slowest consumer gates slot reuse and producers may wait indefinitely | Single/multi-producer full-buffer tests; write-safety cache tests | No nonblocking/timeout guarantee; avoid cyclic publishing from a handler |
| Capacity is a nonzero power of two; batch size is 1 through capacity | Init test, batch-size validation test; zero-capacity check is source evidence | Document both validation errors, including capacity 1 |
| Callback acknowledges only a consumed prefix; unconsumed suffix is retried, including when returning zero | `test/ring_buffer_batch.zig`: partial and zero consumption in running/draining and across restart | `0 <= n <= events.len`; zero does not yield or call the wait strategy automatically |
| Batches stop at max size, physical wrap, or an unpublished sequence | Batch size/wrap/end-of-queue and stale/unpublished claim tests | Batch size is an upper bound, never a promise to fill a batch |
| Events are assigned by value; pointed-to data is not deep-copied or freed; callback slice borrows ring storage | Assignment in `produce`, allocations in `init`/`deinit` (source); no dedicated lifetime test | Caller keeps pointees alive until all handlers finish; do not retain ring slices |
| Shared mutable application data needs synchronization, or exclusive thread ownership followed by join | Thread model and callback type (source/application obligation) | `[]const T` does not make pointees immutable; context example uses atomic updates |
| Initializing thread owns start/stop | `start and stop require lifecycle owner` | Other-thread calls return `NotLifecycleOwner`; ownership does not transfer with the value |
| Publish only after start returns; double start fails | DuplicateStart test; state switches in `produce` (source for other states) | Start/stop are not idempotent; distinguish lifecycle state errors |
| Finish/join every producer before stop; stop drains completed publications and joins handlers; restart retains progress | Single/multi-producer drain/restart and batching tests; stop source comment | Concurrent stop/production has no drain guarantee; keep bus address stable while workers use it |
| Init frees partial allocations; failed start stops already-created handlers; deinit only frees bus storage | `errdefer` and `deinit` in source; no dedicated allocation/thread-spawn failure test | Do not call stop after failed start; do not deinit a running bus |
| Strategy is a type with `pub fn wait() void`, no receiver | `test/waiting_strategy.zig` and validator's function coercion | Document actual signature despite the validator's diagnostic mentioning a receiver |
| Root exports EventBus, EventHandler, waiting_strategy, and hello | `src/root.zig` (source) | Error/state types are not root exports; do not present storage fields as configuration APIs |

The six executable examples add usage verification with explicit result checks,
not new test cases. CI retains the existing suite as behavior evidence. Future
behavior changes should update this map, guides, reference, examples, and relevant
tests together. Failure-path coverage above remains source-reviewed evidence,
not a claim of a tested guarantee.
