---
title: Public API
description: Event bus and storage methods, handler and waiting contracts, and errors.
---

Import the module with `const zigrupt = @import("zigrupt");`. The public
exports are defined in
[`src/root.zig`](https://github.com/sarthakvk/zigrupt/blob/main/src/root.zig).

## EventBus

```zig
zigrupt.EventBus(T, multi_producer, event_handlers,
    PublisherWaitingStrategy, ConsumerWaitingStrategy) type
```

`EventBus` creates a bus type. All five arguments must be known when the type
is formed.

| Argument | Contract |
| --- | --- |
| `T: type` | Event value type stored in the ring |
| `multi_producer: bool` | `false` for one publisher; `true` for concurrent publishers |
| `event_handlers: []const EventHandler(T)` | Fixed ordered list of registrations, each with its own thread and progress |
| `PublisherWaitingStrategy: type` | A type with `pub fn wait() void`, used for capacity waits |
| `ConsumerWaitingStrategy: type` | A type with `pub fn wait() void`, used for startup/publication waits |

An empty handler list is accepted and delivers no events to application code.
Most applications register at least one handler. Treat the returned bus as an
owned value; do not copy it to create another owner.

### init

```zig
Bus.init(allocator: std.mem.Allocator, buffer_size: usize, max_batch_size: usize) !Bus
```

Allocates storage and returns an idle bus owned by the calling thread.
`buffer_size` must be a nonzero power of two. `max_batch_size` must be between 1
and capacity inclusive. Allocation failures unwind allocations already made.
Errors: `IncorrectBufferSize`, `IncorrectBatchSize`, and allocator errors.

### start

```zig
bus.start() !void
```

Owner-thread operation on an idle bus. Creates one thread per handler and returns
in the running state. A thread-spawn error joins any already-started handlers
and returns the bus to idle. Errors: `NotLifecycleOwner`, `BusStarting`,
`BusRunning`, `BusDraining`, and errors propagated by `std.Thread.spawn`.

### produce

```zig
bus.produce(event: T) !void
```

Publishes one event value while the bus is running. It may wait indefinitely for
ring capacity after claiming a sequence. A successful return does not mean any
handler has finished. The bus copies the event value, but neither copies nor
owns data it points to. Single-producer mode requires one publisher at a time;
multi-producer mode supports concurrent calls. Errors: `BusIdle`, `BusStarting`,
`BusDraining`.

### stop

```zig
bus.stop() !void
```

Owner-thread operation. The caller must finish and join all producers first.
Transitions running (or starting during startup cleanup) to draining, joins all
handler threads, and returns to idle. Drain completion depends on handlers making
progress; there is no timeout. Errors: `NotLifecycleOwner`, `BusIdle`, `BusDraining`.

### deinit

```zig
bus.deinit() void
```

Frees bus allocations. It does **not** stop threads, drain events, or free data
referenced by events. Only call once the bus is idle and no thread is accessing
it. Do not use the bus afterward.

## EventHandler

```zig
zigrupt.EventHandler(T) type // *const fn ([]const T) usize
```

The callback receives a nonempty contiguous slice and returns the number of
events consumed from its start, between zero and the slice length. Acknowledged
slots may be reused once every handler has passed them. The remaining suffix
is offered again after partial or zero consumption. The bus does not validate
the returned count.
See [batching](/guides/batching/) and [ownership](/guides/ownership/).

## RingBuffer

```zig
zigrupt.RingBuffer(T: type) type
```

Creates fixed-capacity storage indexed by sequence. A sequence maps to
`sequence & (buffer_size - 1)`, including sequence zero. Sequences one capacity
apart refer to the same reusable slot, which holds only its current value.

Callers must synchronize shared access, make writes visible before reading,
and finish reading a slot before overwriting it. Storage access does not claim
sequences, track publication, or enforce safe slot reuse. Only read slots
initialized with `save`. Do not copy an initialized ring to create another owner.

### init

```zig
Ring.init(allocator: std.mem.Allocator, buffer_size: usize) !Ring
```

Allocates uninitialized storage. `buffer_size` must be a nonzero power of two.
Errors: `IncorrectBufferSize` and allocator errors.

### get

```zig
ring.get(sequence: usize) *const T
```

Borrows the slot for `sequence`. The pointer refers to reusable storage and
sees replacement values when the slot is safely overwritten.

### save

```zig
ring.save(sequence: usize, event: T) void
```

Copies `event` into its slot. Pointers and slices within the event remain
caller-owned. This operation does not wait for readers or publish the event.

### slice

```zig
ring.slice(sequence: usize, max_len: usize) []const T
```

Borrows consecutive physical slots starting at the mapped index. Its length is
`min(max_len, buffer_size - (sequence & (buffer_size - 1)))`, so it never crosses
the physical ring boundary. A zero `max_len` returns an empty slice. It does not
check whether slots have been initialized or published. Both `get` and `slice`
accept a const receiver.

### deinit

```zig
ring.deinit() void
```

Frees the ring allocation after all accesses have finished, invalidating all
borrowed slot pointers and slices. It does not release resources referenced
by event values. Keep the allocator valid through this call and do not use
the ring afterward.

## waiting_strategy

`zigrupt.waiting_strategy.BusySpin` is a type exposing `pub fn wait() void` which
immediately returns.

`zigrupt.waiting_strategy.validateWaitingStrategy(comptime Strategy: type) void`
requires a `wait` declaration compatible with `fn () void` and produces a
compile error when the contract is not met. The function takes **zero**
arguments, even if a compiler diagnostic mentions `self`.
See [custom waiting strategies](/guides/waiting-strategies/).

## Errors

Match method errors using ordinary Zig error literals. `EventBusError` is not
exported from the root module.

| Error | Meaning / operation |
| --- | --- |
| `IncorrectBufferSize` | `EventBus.init`/`RingBuffer.init`: zero or non-power-of-two capacity |
| `IncorrectBatchSize` | `EventBus.init`: zero batch size or larger than capacity |
| `NotLifecycleOwner` | `start`/`stop`: caller is not the initializing thread; checked before state |
| `BusIdle` | `produce`/`stop`: bus is idle |
| `BusStarting` | `produce`/`start`: bus is starting |
| `BusRunning` | `start`: bus already runs |
| `BusDraining` | `produce`/`start`/`stop`: bus is draining |
| Allocator errors | `EventBus.init`, `RingBuffer.init`, and possibly thread creation |
| Thread-spawn errors | `start`: propagated from Zig's thread implementation, platform dependent |

## State and implementation fields

The lifecycle states are `idle`, `starting`, `running`, and `draining`.
`EventBusState` is not a root export. The bus's `buffer`, sequence counters,
thread handles, and state atomic are implementation details. Direct access to
bus storage bypasses publication and slot-reuse coordination; use `produce()`
and handler callbacks for event delivery, and bus methods for lifecycle
transitions.
