---
title: Getting started
description: Add zigrupt to a Zig project and run a small example.
---

### Add the dependency

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
const zigrupt = b.dependency("zigrupt", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zigrupt", zigrupt.module("zigrupt"));
```

### Try it

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

Continue with [concepts](/zigrupt/concepts/) and
[event ownership](/zigrupt/guides/ownership/) before passing pointers or slices.
