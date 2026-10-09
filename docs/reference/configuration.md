---
title: Configuration
description: Type-level choices, runtime capacity, and batch-size constraints.
---

## When defining the bus type

Choose the event type, producer mode, fixed handler list, and publisher and
consumer waiting strategies in `EventBus(...)`. These choices determine the
returned Zig type, so handlers cannot be added at runtime. To pass context to
a callback, carry a pointer in the event.

## When initializing a bus

| `init` argument | Valid values | Consequence |
| --- | --- | --- |
| `allocator` | A valid allocator lasting through `deinit()` | Owns ring and bookkeeping allocations |
| `buffer_size` | Nonzero power of two, including 1 | Number of reusable event slots |
| `max_batch_size` | 1 through `buffer_size` inclusive | Upper bound on a handler's contiguous callback slice |

These arguments have no defaults. The first program uses capacity 64 and batch
limit 8 to demonstrate the API. The batch limit need not be a power of two.

Larger capacity uses more memory and can absorb bursts before backpressure.
Larger batches can reduce callback overhead, but a handler acknowledges its
consumed prefix only when the callback returns. Waiting strategies affect CPU
usage while waiting for capacity or publication. Measure the trade-offs using
the [benchmark methodology](https://github.com/sarthakvk/zigrupt/blob/main/benchmarks/README.md).

Configuration is independent of lifecycle ownership: the thread that initializes
the bus owns startup and shutdown even if another thread is its sole publisher.
