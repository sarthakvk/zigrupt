---
title: Implementation tour
description: Source map and sequence mechanics for contributors.
---

For application code, use the [public API](/reference/api/) and
[usage contracts](/concepts/).

## Source map

| File                       | Responsibility                                                                             |
| -------------------------- | ------------------------------------------------------------------------------------------ |
| `src/root.zig`             | Public aliases and waiting-strategy module export                                          |
| `src/ring_buffer.zig`      | Bus type factory, sequencers, slot publication, consumer loops, lifecycle                  |
| `src/waiting_strategy.zig` | Strategy signature validation and BusySpin                                                 |
| `test/`                    | Behavior evidence for single/multi-producer operation, batching, lifecycle, waiting        |
| `benchmarks/`              | Cross-language benchmark adapters, correctness checks, and throughput/latency measurements |

## Sequences and slot reuse

Sequences begin at 1. The producer cursor points to the next unclaimed sequence;
each consumer sequence points to the next event it needs. Power-of-two capacity
allows a sequence to map to a slot through `sequence & mask`. The first event
therefore occupies index 1 except at capacity 1; code must not assume index 0
is the first publication.

The single-producer sequencer advances one producer's cursor; the multi-producer
sequencer claims positions with atomic fetch_add RMW operation. Publication markers
identify which sequence occupies each slot. Claims alone do not publish data:
consumers wait at a publication gap rather than skip to a later event.

Producers cache a safe-to-write limit derived from the minimum consumer sequence.
Progress counters are aligned to reduce cache-line sharing. Consult the
write-safety cache tests before changing this path.

## Publication and acknowledgement

A producer assigns the event and release-stores its sequence marker. Consumers
acquire-load the marker before reading the corresponding event. A handler's
returned prefix advances its release-stored progress, which producers acquire
when deciding whether reuse is safe. These relationships establish publication
and slot-reuse ordering; they do not protect unrelated application mutations.

Consumer batches extend only across consecutive published sequences in the
same physical slice, capped by the configured limit. Both running and draining
loops honor partial acknowledgements. The drain loop bounds itself by the
producer cursor after the application has completed production.

## Lifecycle and evidence

`init()` records the lifecycle owner's thread ID. Startup creates handlers in
`starting`, then releases them into `running`. Stop enters `draining`, joins the
threads, clears thread handles, and returns to `idle`; it does not reset the
sequences. Partial startup failure uses the stop path for cleanup.

When changing these paths, keep source comments, examples, and the
[public API reference](/reference/api/) consistent with the resulting
behavior.
