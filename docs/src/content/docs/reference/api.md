---
title: Public API
description: Bus construction, methods, handler and waiting contracts, and errors.
---

Import the module with `const zigrupt = @import("zigrupt");`. This handwritten
reference covers the exports of
[`src/root.zig`](https://github.com/sarthakvk/zigrupt/blob/main/src/root.zig).
It follows the existing source comments and implementation; the
[behavior checklist](https://github.com/sarthakvk/zigrupt/blob/main/docs/behavior-checklist.md)
maps claims to existing tests and identifies source-only evidence.

## EventBus

```zig
zigrupt.EventBus(T, multi_producer, event_handlers,
    PublisherWaitingStrategy, ConsumerWaitingStrategy) type
```

An alias of the internal `RingBufferEventBus` type factory. All five arguments
must be known when forming the type, even where the source signature does not
spell out `comptime`.

| Argument | Contract |
| --- | --- |
| `T: type` | Event value type stored in the ring |
| `multi_producer: bool` | `false` for one publisher; `true` for concurrent publishers |
| `event_handlers: []const EventHandler(T)` | Fixed ordered list of registrations, each with its own thread and progress |
| `PublisherWaitingStrategy: type` | A type with `pub fn wait() void`, used for capacity waits |
| `ConsumerWaitingStrategy: type` | A type with `pub fn wait() void`, used for startup/publication waits |

An empty handler list is accepted by the implementation and delivers no events
to application code. Typical usage has at least one handler. Treat the returned
bus as an owned value: do not copy it to create another owner.

### init

```zig
Bus.init(allocator: std.mem.Allocator, buffer_size: usize, max_batch_size: usize) !Bus
```

Allocates storage and returns an idle bus owned by the current thread.
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

Publishes one copied event value while running. May wait indefinitely for ring
capacity after claiming its sequence. Successful return does not mean consumer
completion. Pointees are not copied or owned by the bus. One producer at a time
is required in single-producer mode; multi-producer mode supports concurrent
calls. Errors: `BusIdle`, `BusStarting`, `BusDraining`.

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

The callback receives a nonempty contiguous slice and returns the length of the
consumed prefix, bounded by the slice length. Acknowledged slots may be reused
once all consumers have passed them. The suffix is offered again after partial
or zero consumption. No bound check protects an invalid returned count.
See [batching](/zigrupt/guides/batching/) and [ownership](/zigrupt/guides/ownership/).

## waiting_strategy

`zigrupt.waiting_strategy.BusySpin` is a type exposing `pub fn wait() void` which
immediately returns.

`zigrupt.waiting_strategy.validateWaitingStrategy(comptime Strategy: type) void`
checks for a `wait` declaration compatible with `fn () void`, producing a
compile error if the contract is not met. The current missing-declaration
diagnostic mentions `self`, but the enforced contract takes **zero** arguments.
See [custom waiting strategies](/zigrupt/guides/waiting-strategies/).

## hello

`zigrupt.hello() void` prints `hello, from zigrupt lib!!!` followed by a newline
using `std.debug.print`. It is an existing diagnostic export; event-bus setup
does not require calling it.

## Errors

The inferred method error sets can be matched using ordinary Zig error literals.
`EventBusError` is declared in the implementation file but is not re-exported
from the root module. Do not import a nonexistent `zigrupt.EventBusError`.

| Error | Meaning / operation |
| --- | --- |
| `IncorrectBufferSize` | `init`: zero or non-power-of-two capacity |
| `IncorrectBatchSize` | `init`: zero batch size or larger than capacity |
| `NotLifecycleOwner` | `start`/`stop`: caller is not the initializing thread; checked before state |
| `BusIdle` | `produce`/`stop`: bus is idle |
| `BusStarting` | `produce`/`start`: bus is starting |
| `BusRunning` | `start`: bus already runs |
| `BusDraining` | `produce`/`start`/`stop`: bus is draining |
| Allocator errors | `init`, and possibly thread creation |
| Thread-spawn errors | `start`: propagated from Zig's thread implementation, platform dependent |

The implementation also declares `InvalidConfig` and `InvalidConsumerID`, but
current public operations do not emit them. Their presence does not establish
additional configuration or consumer-ID APIs.

## State and implementation fields

The lifecycle states are `idle`, `starting`, `running`, and `draining`.
`EventBusState` is not a root export. Storage fields such as sequences, thread
handles, and the state atomic are implementation details, not supported
application configuration controls. Use methods for lifecycle transitions;
directly modifying internal fields bypasses their contracts.
