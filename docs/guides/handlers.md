---
title: Handlers and application context
description: Use plain callback functions and pass context with explicit ownership.
---

`EventHandler(T)` is `*const fn ([]const T) usize`. A handler receives a nonempty,
contiguous slice of events and returns the number it consumed, starting at index
zero. It has no error return, closure capture, or separate context argument.
Keep application error policy inside the handler: for example, record an error
in synchronized application state and acknowledge according to your policy.
The bus does not automatically retry failed operations or undo side effects.

## Passing context through an event

An event can carry a pointer to application context. This example also carries
a slice backed by separately allocated storage. The context and bytes remain
alive until both handlers finish. The counter is atomic because the two
registrations of `handle` run on separate threads.

```sh
zig build example-context
```

<!-- snippet: examples/context.zig -->
```zig
const std = @import("std");
const zigrupt = @import("zigrupt");

const Context = struct {
    // Two handler threads update this same object, so the counter is atomic.
    bytes_seen: std.atomic.Value(usize) = .init(0),
};
const Event = struct { context: *Context, text: []const u8 };

fn handle(events: []const Event) usize {
    for (events) |event| {
        _ = event.context.bytes_seen.fetchAdd(event.text.len, .monotonic);
    }
    return events.len;
}
const Bus = zigrupt.EventBus(
    Event,
    false,
    &.{ handle, handle },
    zigrupt.waiting_strategy.BusySpin,
    zigrupt.waiting_strategy.BusySpin,
);

pub fn main() !void {
    var context: Context = .{};
    // The slice points into separately owned storage; produce does not copy it.
    const text = try std.heap.page_allocator.dupe(u8, "hello");
    defer std.heap.page_allocator.free(text);

    var bus = try Bus.init(std.heap.page_allocator, 8, 4);
    defer bus.deinit();
    try bus.start();
    errdefer bus.stop() catch {};
    for (0..10) |_| try bus.produce(.{ .context = &context, .text = text });
    try bus.stop(); // Both context and text outlive every handler access.

    const bytes = context.bytes_seen.load(.monotonic);
    if (bytes != 100) return error.UnexpectedByteCount;
    std.debug.print("context: two handlers counted {d} bytes\n", .{bytes});
}
```
<!-- end:examples/context.zig -->

`[]const Event` prevents writing the event fields through the slice. It does not
make `event.context.*` immutable, prevent another producer from mutating it, or
extend any lifetime. Use immutable data, distinct per-handler state, or explicit
synchronization for mutable shared objects.

The [basic example](/getting-started/#try-it) uses one global
counter owned exclusively by one handler and reads it only after `stop()` joins
that handler. If multiple handlers or buses write the same counter, synchronize
those writes.

See [batching](/guides/batching/) for consumed-prefix rules and
[ownership](/guides/ownership/) for lifetime details.
