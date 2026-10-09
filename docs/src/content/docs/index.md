---
title: zigrupt
description: A Disruptor-inspired broadcast event bus for Zig.
---

zigrupt is a Zig implementation of the LMAX Disruptor approach to passing events
between threads: producers publish into a fixed-capacity ring, and independent
handlers consume the same ordered stream. It can be useful when multiple parts
of an application need to process every event, with bounded event storage and
backpressure from consumers.

The library is under active development. The package currently declares version
0.0.1 and requires Zig 0.16.0; API stability is not yet promised. These docs track
implemented behavior on `main`. The present API is a starting point, not a limit
on the project's direction. No full LMAX feature parity, durability, or measured
performance advantage is implied.

## Start here

- [Install and run your first program](/zigrupt/getting-started/).
- [Understand broadcast and backpressure](/zigrupt/concepts/).
- [Choose producer mode and runtime configuration](/zigrupt/reference/configuration/).
- [Look up the public API](/zigrupt/reference/api/).
- [Run the canonical examples](https://github.com/sarthakvk/zigrupt/tree/main/examples).

## Available today

Single- and multi-producer modes, one thread per registered handler, bounded
consumer batches, consumed-prefix acknowledgements, custom waiting strategies,
and owner-thread startup, draining, and restart are implemented. Handlers are
selected when defining the bus type.

Delivery is broadcast, not a pool in which workers divide events. The current
API does not provide consumer dependency graphs, dynamic handler registration,
durable storage, a bulk publishing call, or timeout/try-publish methods. These
are descriptions of the current API, not a roadmap or permanent exclusions.

See [contributing](/zigrupt/contributing/workflow/) for how to update these pages
as capabilities evolve. The project uses the
[MIT license](https://github.com/sarthakvk/zigrupt/blob/main/LICENSE).
