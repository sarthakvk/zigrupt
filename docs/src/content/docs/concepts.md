---
title: Concepts
description: Ring buffers, ordered broadcast, independent handlers, and backpressure.
---

The Disruptor approach separates claiming a place in an event stream, publishing
its value, and recording each consumer's progress. zigrupt uses this approach to
reuse a fixed allocation of event slots across threads. Basic usage does not
require understanding atomic memory ordering.

![Producers publish into a ring buffer which broadcasts to independent handlers. The slowest handler's progress gates slot reuse.](../../assets/broadcast.svg)

## A ring of reusable slots

A ring buffer wraps around when it reaches its capacity. A sequence identifies
an event's position in the stream across those wraps; a slot alone does not.
The producer cannot overwrite a slot until every handler has acknowledged its
previous event. Capacity bounds the number of stored event values, not memory
owned elsewhere and referenced by events.

## Broadcast and order

Every registered handler receives every published event, in the same global
sequence order, provided the application follows the lifecycle and callback
contracts. Each registration has its own progress and thread. Handler A may
finish long before handler B. There is no ordering of side effects *between*
handlers, and their batch boundaries may differ.

This is useful for independent consumers such as an audit stream and a metrics
collector. It does not distribute one event to just one available worker.
Returning a partial count can cause another callback for the remaining events;
application side effects are not an exactly-once transaction mechanism.

With multiple producers, sequential calls from one producer remain ordered.
The interleaving between producers is unspecified. An earlier claimed event
must be published before consumers can pass it, even if a later producer's
`produce()` call has already returned.

## Backpressure

The slowest handler controls when slots become reusable. If it falls behind by
the capacity, producers wait. A larger ring can absorb a burst but cannot fix a
sustained mismatch between producer and consumer rates. A handler that never
acknowledges progress can stall both publishing and shutdown indefinitely.

A successful `produce()` means the event is published, not that any handler has
finished. There is currently no publish timeout or nonblocking alternative.

## Threads and coordination

`start()` creates one operating-system thread per handler registration. Producers
are application threads; the library does not create them. Callbacks for one
registration are serial, but separate registrations run concurrently. Registering
the same function twice still creates two concurrent consumers.

The thread that calls `init()` owns `start()` and `stop()`. Producers must finish
before that owner stops the bus. Share results with atomics, locks, or exclusive
ownership followed by thread joins; the bus does not synchronize arbitrary
application accesses outside publication and acknowledgement.

See [producer modes](/zigrupt/guides/producers/),
[batching](/zigrupt/guides/batching/), and [lifecycle](/zigrupt/guides/lifecycle/)
for executable patterns.
