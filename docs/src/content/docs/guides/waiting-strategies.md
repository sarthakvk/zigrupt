---
title: Waiting strategies
description: Implement the zero-argument wait contract and understand where it runs.
---

Pass a publisher strategy type and a consumer strategy type to `EventBus`.
Each must expose exactly `pub fn wait() void`: a static, zero-argument function
with no receiver or error return. No strategy instance is allocated or passed
by the bus. The type is validated when the bus type is instantiated.

`waiting_strategy.BusySpin` is the current built-in strategy. Its `wait()`
returns immediately. Loops using it repeatedly poll, potentially occupying a
CPU core. Choose behavior according to your latency, CPU, and scheduling needs;
there is no universal fastest strategy.

## A yielding strategy

```sh
zig build example-waiting_strategy
```

<!-- snippet: examples/waiting_strategy.zig -->
```zig
const std = @import("std");
const zigrupt = @import("zigrupt");

const Yield = struct {
    // A static zero-argument function, with no self pointer or error return.
    pub fn wait() void {
        std.Thread.yield() catch {};
    }
};
comptime {
    zigrupt.waiting_strategy.validateWaitingStrategy(Yield);
}

var count: usize = 0;
fn handle(events: []const usize) usize {
    count += events.len;
    return events.len;
}
const Bus = zigrupt.EventBus(usize, false, &.{handle}, Yield, Yield);

pub fn main() !void {
    var bus = try Bus.init(std.heap.page_allocator, 8, 4);
    defer bus.deinit();
    try bus.start();
    errdefer bus.stop() catch {};
    for (0..100) |value| try bus.produce(value);
    try bus.stop();
    if (count != 100) return error.MissingEvents;
    std.debug.print("waiting_strategy: 100 events delivered using Yield\n", .{});
}
```
<!-- end:examples/waiting_strategy.zig -->

Yielding asks the scheduler to let another thread run, but does not guarantee a
switch or a particular delay. Compare under representative workloads.

## Where wait is called

The publisher strategy runs while a claimed slot is not yet safe to reuse.
The consumer strategy runs while startup is finishing and while a running
consumer is waiting for its next publication. It is not a callback after every
batch, and returning zero from a handler does not invoke it. The drain loop does
not use it to wait for missing publications, which is another reason producers
must complete before `stop()`.

A strategy can be called concurrently by multiple producers or consumers. Any
shared mutable strategy state requires synchronization; state specific to a
thread can use appropriate thread-local storage. Strategies must eventually
return so the bus can recheck progress. The current interface supplies no
notification/wakeup registration, so indefinite parking requires coordination
outside this API and can prevent progress.
