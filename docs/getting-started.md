---
title: Getting started
description: Add zigrupt to a Zig project and run a small example.
---

## Add the dependency

In a new project, run:

```sh
mkdir zigrupt-demo
cd zigrupt-demo
zig init
zig fetch --save=zigrupt git+https://github.com/sarthakvk/zigrupt.git
```

In `build.zig`, add these lines after the `exe` declaration so `main.zig` can
import zigrupt:

```zig
const zigrupt = b.dependency("zigrupt", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zigrupt", zigrupt.module("zigrupt"));
```

## Try it

Replace `src/main.zig` with:

```zig
const std = @import("std");
const zigrupt = @import("zigrupt");

const Event = struct { value: usize };

fn handle(events: []const Event) usize {
    for (events) |event| std.debug.print("{d}\n", .{event.value});
    return events.len;
}

const BusySpin = zigrupt.waiting_strategy.BusySpin;
const Bus = zigrupt.EventBus(Event, false, &.{handle}, BusySpin, BusySpin);

pub fn main() !void {
    var bus = try Bus.init(std.heap.page_allocator, 64, 8);
    defer bus.deinit();
    try bus.start();
    errdefer bus.stop() catch {};

    try bus.produce(.{ .value = 42 });
    try bus.stop();
}
```

```sh
zig build run
```

This prints `42`.

## Choose capacity and batch size

In `Bus.init(allocator, 64, 8)`, `64` is the ring capacity and `8` is the
maximum number of events offered to a handler in one callback. Capacity must
be a nonzero power of two, and the batch limit must be between one and capacity
inclusive.

A larger ring absorbs longer bursts but uses more storage; it does not remove
[slow-handler backpressure](/concepts/#backpressure). The batch limit controls
how much work a handler receives at once, not how long the bus waits to collect
it. See [batching](/guides/batching/) for acknowledgement and retry rules.

The event type, producer mode, handlers, and waiting strategies are fixed when
defining `Bus`; capacity and batch size are chosen when initializing each
instance. The example uses one producer and one handler. See
[producer modes](/guides/producers/) before publishing concurrently.

Continue with [concepts](/concepts/) and
[event ownership](/guides/ownership/) before passing pointers or slices.
