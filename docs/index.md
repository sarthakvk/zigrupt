---
title: Home
description: A high-performance event broadcasting library for Zig.
---

![Zigrupt logo](assets/zigrupt_logo.png)

Zigrupt is a high-performance event broadcasting library for Zig, heavily
inspired by the original [LMAX Disruptor](https://github.com/LMAX-Exchange/disruptor).
It lets application threads publish events once and have multiple handlers
process every event, in order, on their own threads. A fixed-capacity ring
buffer, lock-free coordination, and attention to CPU cache lines keep the path
between producers and handlers lean.

:::caution[Warning]
Zigrupt is under active development. The API is not yet stable and may change.
:::

## Why broadcast?

A work queue assigns an event to one worker. zigrupt gives each registered
handler the full stream. For example, one handler can update live metrics while
another writes an audit trail. They work independently and may finish at
different times, but neither misses an event because the other received it.

## How an event moves

A producer publishes a value into the next reusable slot in the ring. Each
publication has a sequence number, so handlers can follow the stream in order
even after the ring wraps around. Every handler tracks which events it has
processed and acknowledges its progress separately.

The ring reuses a slot only after **all** handlers have finished with its
previous event. If the slowest handler falls a full ring behind, producers wait
for capacity instead of overwriting unread data. A successful publication means
the event is available to handlers; it does not wait for them to finish.

## Built for busy event streams

The ring allocates a bounded set of slots up front and reuses them as events
flow through. Atomic, lock-free coordination avoids a mutex on the publication
path, while cache-line-aware layout reduces false sharing between threads.
Choose single- or multi-producer mode, tune how handlers wait for new events,
and process events in batches to match the workload and available CPU time.

## Start here

- [Install and run your first program](/getting-started/).
- [Understand broadcast and backpressure](/concepts/).
- [Choose capacity and batch size](/getting-started/#choose-capacity-and-batch-size).
- [Publish from one or multiple producers](/guides/producers/).
- [Manage startup and shutdown](/guides/lifecycle/).
- [API docs](/apidocs/).
- [See the measured performance comparison](/performance/).
- [Run the canonical examples](https://github.com/sarthakvk/zigrupt/tree/main/examples).

The project uses the [MIT license](https://github.com/sarthakvk/zigrupt/blob/main/LICENSE).
