---
title: Event ownership and lifetimes
description: Understand copied values, borrowed ring slices, and shared pointees.
---

`produce(event)` copies an event value into preallocated ring storage. Scalars
and inline arrays are copied with the value. For pointers, slices, and allocator
handles, only their fields are copied. The bus does not copy the data they
reference, take ownership of it, or release it automatically.

## Borrowed event slices

A callback borrows the ring's event slice. Use it during the callback; do not
retain the slice or a pointer to a ring slot for later work. Once acknowledged
by every handler, that slot can be reused. Copy any data you need to retain into
storage owned by your application before acknowledging it.

If a handler hands work to another thread, either copy the necessary data or
explicitly manage the pointee's ownership beyond the callback. `stop()` joins
bus handlers, not tasks that your callbacks start elsewhere.

## Data referenced by events

A producer can continue after `produce()` returns while handlers still need its
data. A slice into a producer's temporary stack buffer is unsafe if the buffer
is reused or goes out of scope too soon. Keep referenced storage alive and
suitably synchronized until **all** handlers have finished using it.
For simple programs, keep storage alive through `stop()` after joining producers.
For long-lived streams, design an application-level reclamation protocol.

Broadcast makes freeing data in the first handler unsafe: another handler may
still need it. `deinit()` only releases allocations made by the bus. It never
frees event pointees. The [context example](/guides/handlers/) shows a
simple lifetime arrangement with separately owned bytes.

## Shared application state

Initialization before publication is visible through the bus's publication
protocol. Later unsynchronized mutations of pointed-to data are not protected.
Consumers can run simultaneously, so use immutable data, atomics, or locks as
appropriate. An atomic counter protects that counter, not neighboring fields.

Keep the bus at a stable address after starting it; worker threads retain its
pointer. Do not copy an initialized bus as an independent owner or deinitialize
both copies. The allocator and anything it depends on must remain valid through
`deinit()`. Release resources in this order: finish producers, drain/join handlers,
deinitialize the bus, then release event/context storage when no application
workers still need it.
