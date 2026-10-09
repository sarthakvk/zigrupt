---
title: Batching and acknowledgements
description: Process an ordered prefix and acknowledge only completed work.
---

`max_batch_size` limits how many events a handler can receive in one callback.
It is an upper bound, not a target the bus waits to fill. A batch can be shorter
because fewer consecutive events are published, the ring wraps, or draining
reaches the end of the queue. Producer calls still publish one event at a time.

## Consumed prefixes

For a slice of length `L`, return `n` with `0 <= n <= L`. Only events `[0..n]`
are acknowledged. Returning `L` consumes the whole slice; a smaller value leaves
the suffix for a later call, possibly alongside newly available events.
Do not process the suffix and then acknowledge only the prefix: the suffix's
side effects would be repeated. The caller must enforce the returned-count bound;
the implementation does not validate it for you.

Returning zero acknowledges nothing. The next callback begins at the same event.
The bus does not automatically sleep, yield, or invoke the waiting strategy just
because a callback returned zero. A permanently zero-returning handler can spin,
block producers, and prevent `stop()` from completing. Retry only if your
application can actually make progress.

```sh
zig build example-batching
```

<!-- snippet: examples/batching.zig -->
```zig
const std = @import("std");
const zigrupt = @import("zigrupt");

var next: usize = 0;
var retried: bool = false;

fn handle(events: []const usize) usize {
    if (events.len == 0 or events.len > 8) @panic("unexpected batch size");
    if (!retried) {
        retried = true;
        return 0; // No side effects on events; retry this prefix once.
    }
    // Process at most two events even if a larger contiguous batch is offered.
    const consumed = @min(events.len, 2);
    for (events[0..consumed]) |event| {
        if (event != next) @panic("unexpected event or duplicate processing");
        next += 1;
    }
    return consumed; // Acknowledge exactly the prefix processed above.
}
const Bus = zigrupt.EventBus(usize, false, &.{handle}, zigrupt.waiting_strategy.BusySpin, zigrupt.waiting_strategy.BusySpin);

pub fn main() !void {
    var bus = try Bus.init(std.heap.page_allocator, 16, 8);
    defer bus.deinit();
    try bus.start();
    errdefer bus.stop() catch {};
    for (0..100) |value| try bus.produce(value);
    try bus.stop();
    if (next != 100 or !retried) return error.UnexpectedConsumption;
    std.debug.print("batching: 100 events consumed in order after one retry\n", .{});
}
```
<!-- end:examples/batching.zig -->

The example deliberately retries once, then processes at most two events from
each offered slice. It verifies final order and count without assuming a particular
batch schedule. Prefix retry rules also apply while draining and after restart.
