---
title: Internals
description: How producers and handlers share a ring, preserve event order, and decide when storage can be reused.
---

Zigrupt stores events in a fixed-size ring buffer shared by producers and
handlers. Producers write events into it; each handler reads those same events
on its own thread. There is no separate queue or copy of the events for each
handler.

Before reading an event, a handler needs to know that its producer has finished
writing it. Before reusing a slot, a producer needs to know that every handler
has finished with the previous event there. Publication tells handlers an event
is ready; acknowledgements tell producers which events each handler has consumed.

## Storage and coordination

The bus is built from three components:

- **Ring buffer:** holds the event values. It maps a sequence number to a storage
  slot and can lend a slice of adjacent slots to a handler. It does not track
  whether those values are ready to read or safe to overwrite.
- **Sequencer:** assigns sequence numbers to producers, records which events
  have been published, and tracks how far each handler has read. It uses this
  information to decide which events are available and which slots can be reused.
  It does not read or write event values.
- **Event bus:** connects the two. It writes producers' events, runs handler
  threads, passes event slices to callbacks, and manages startup and shutdown.
  When a producer or handler cannot proceed, the bus uses its waiting strategy
  before checking again.

The ring has a fixed number of slots, but sequence numbers keep increasing
across wraps. In a four-slot ring, events 1 and 5 use the same slot, as do events
2 and 6. The sequence identifies the event; the slot is just where that event
is stored.

## From a producer call to a readable event

A producer first claims the next sequence number. Claiming gives that producer's
event a position in the shared stream; it does not write the event or make it
readable. If the slot still holds an event that a handler needs, the producer
waits. Once the slot is reusable, the producer copies its event into it and
marks that sequence as published.

With multiple producers, these steps can finish out of order. Suppose producer
A claims sequence 5 and pauses, while producer B claims 6 and publishes it.
A handler waiting for 5 cannot skip ahead to 6. It waits until A publishes 5,
then reads 5 before 6. The order is determined by claims, not by which producer
finishes first.

Publication is recorded separately for each slot, using the event's sequence
number. In the four-slot example, a marker for event 1 must not count as
publication of event 5, even though they share a slot. A handler checks that
the marker names the exact event it is waiting for.

Publishing also makes the preceding event write visible to handlers that observe
its publication. A handler must not read a slot merely because its sequence has
been claimed.

## How handlers advance

Each handler tracks its own next unread sequence, initially 1. Handlers do not
compete for events: one handler advancing does not advance any other handler.

Starting at that sequence, the bus finds consecutive published events and lends
them to the callback as a batch. A batch ends at the first unpublished event,
the configured batch-size limit, or the physical end of the ring. Events after
the ring wraps are delivered in another batch because they are not adjacent in
memory. The callback reads directly from the ring; constructing the batch does
not copy its events.

The callback returns how many events it consumed **from the beginning** of the
batch. If a batch contains events 5, 6, and 7 and the callback returns 2, the
handler's next unread sequence becomes 7. Returning zero leaves it at 5. The bus
records that progress as the handler's acknowledgement; unacknowledged events
remain unread and can be offered again.

The slice is borrowed only for the callback. Acknowledging events lets producers
reuse their slots, so retaining references to them after the callback is unsafe.

## When a slot becomes reusable

A producer may overwrite an old event only after every handler has acknowledged
it. That makes the slowest handler determine how far producers can advance.

For example, before writing event 5 into a four-slot ring, the producer needs
every handler to have consumed event 1. If one handler still has 1 as its next
unread sequence, the producer waits, even if all other handlers are much further
ahead. Once that handler advances to 2, the slot holding event 1 is reusable.
The slot holding event 2 is not yet reusable for event 6.

This is how the bounded ring applies backpressure without dropping unread
events. Producers remember an already-checked writable range so they need not
check every handler for each event. They check again when a claim goes beyond
that range.

Acknowledgement is the second thread-synchronization step: it ensures the
handler has finished accessing an event before a producer overwrites it.
Together, publication and acknowledgement protect the shared ring. They do not
make unrelated application data thread-safe; see [event ownership](/guides/ownership/).

## Stopping and restarting

While running, a handler waits when its next event is not yet published. During
shutdown, it instead consumes the remaining published events up to the end of
the claimed stream and exits. It still cannot skip a publication gap: draining
stops at the first missing event rather than waiting for an unfinished producer.
This is why all producer calls must finish before shutdown begins.

Shutdown joins the handler threads, but it does not force callbacks to
acknowledge events. A handler that keeps returning zero can prevent shutdown
from completing.

Restart creates new handler threads without resetting the sequence numbers or
handler progress. They continue from their saved next unread positions rather
than replaying acknowledged events. See [lifecycle](/guides/lifecycle/) for the
application's startup and shutdown responsibilities.

The source is split along the same component boundaries:
[`ring_buffer.zig`](https://github.com/sarthakvk/zigrupt/blob/main/src/ring_buffer.zig),
[`sequencer.zig`](https://github.com/sarthakvk/zigrupt/blob/main/src/sequencer.zig),
and [`event_bus.zig`](https://github.com/sarthakvk/zigrupt/blob/main/src/event_bus.zig).
