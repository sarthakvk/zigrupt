---
title: Configuration
description: Type-level choices, runtime capacity, and batch-size constraints.
---

## When defining the bus type

Choose the event type, single- or multi-producer mode, fixed handler list, and
publisher/consumer waiting strategy types in `EventBus(...)`. These choices
specialize the returned Zig type. Handler registration does not change at runtime.
There is no constructor parameter for a callback context; carry an explicit
pointer in the event when needed.

## When initializing a bus

| `init` argument | Valid values | Consequence |
| --- | --- | --- |
| `allocator` | A valid allocator lasting through `deinit()` | Owns ring and bookkeeping allocations |
| `buffer_size` | Nonzero power of two, including 1 | Number of reusable event slots |
| `max_batch_size` | 1 through `buffer_size` inclusive | Upper bound on a handler's contiguous callback slice |

There are no defaults for these arguments. The basic example uses capacity 64
and batch limit 8 as small demonstration values, not a general tuning recommendation.
The batch limit itself need not be a power of two.

Larger capacity uses more memory and can absorb bursts before backpressure.
Larger batches can reduce callback overhead, but a handler acknowledges its
consumed prefix only when the callback returns. Waiting strategies affect CPU
usage while waiting for capacity or publication. Measure the trade-offs using
the [benchmark methodology](/zigrupt/performance/).

Configuration is independent of lifecycle ownership: the thread that initializes
the bus owns startup and shutdown even if another thread is its sole publisher.
