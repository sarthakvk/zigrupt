const std = @import("std");
const RingBufferEventBus = @import("zigrupt").EventBus;
const waiting_strategy = @import("zigrupt").waiting_strategy;

const capacity = 8;
const event_count = 512;

fn Recorder(comptime id: usize) type {
    return struct {
        var values: [event_count]usize = undefined;
        var count: usize = 0;
        var gate: ?*std.atomic.Value(bool) = null;
        var entered: ?*std.atomic.Value(usize) = null;
        var unique_id = id;

        fn reset() void {
            count = 0;
            gate = null;
            entered = null;
        }

        fn handle(value: usize) void {
            if (count == 0) {
                if (entered) |signal| {
                    _ = signal.fetchAdd(1, .release);
                    while (!gate.?.load(.acquire)) std.Thread.yield() catch {};
                }
            }
            values[count] = value;
            count += 1;
        }

        fn expectRange(start: usize, len: usize) !void {
            try std.testing.expectEqual(len, count);
            for (values[0..len], start..) |value, expected| {
                try std.testing.expectEqual(expected, value);
            }
        }
    };
}

const First = Recorder(0);
const Second = Recorder(1);
const handlers = [_]*const fn (usize) void{ First.handle, Second.handle };
const Bus = RingBufferEventBus(
    usize,
    false,
    &handlers,
    waiting_strategy.BusySpin,
    waiting_strategy.BusySpin,
);

fn publish(bus: *Bus, start: usize, len: usize) void {
    for (start..start + len) |value| {
        // Respect the documented full-buffer precondition: wait until every
        // handler has finished with the slot before publishing its replacement.
        if (value >= capacity) {
            for (bus.consumer_seq) |*consumer| {
                while (consumer.value.load(.acquire) <= value + 1 - capacity) {
                    std.Thread.yield() catch {};
                }
            }
        }
        bus.produce(value) catch unreachable;
    }
}

test "concurrent producer and two handlers preserve order across wraps" {
    First.reset();
    Second.reset();
    var bus = try Bus.init(std.testing.allocator, capacity);
    defer bus.deinit();

    try bus.start();
    const producer = try std.Thread.spawn(.{}, publish, .{ &bus, @as(usize, 0), event_count });
    producer.join(); // No production is in flight when stop begins.
    try bus.stop();

    try First.expectRange(0, event_count);
    try Second.expectRange(0, event_count);
}

fn publishPastFullBuffer(
    bus: *Bus,
    attempting: *std.atomic.Value(bool),
    completed: *std.atomic.Value(bool),
) void {
    for (0..capacity) |value| bus.produce(value) catch unreachable;
    attempting.store(true, .release);
    bus.produce(capacity) catch unreachable;
    completed.store(true, .release);
}

test "publisher waits for a full buffer until handlers advance" {
    First.reset();
    Second.reset();
    var gate = std.atomic.Value(bool).init(false);
    var entered = std.atomic.Value(usize).init(0);
    First.gate = &gate;
    Second.gate = &gate;
    First.entered = &entered;
    Second.entered = &entered;

    var bus = try Bus.init(std.testing.allocator, capacity);
    defer bus.deinit();
    try bus.start();

    var attempting = std.atomic.Value(bool).init(false);
    var completed = std.atomic.Value(bool).init(false);
    const producer = try std.Thread.spawn(.{}, publishPastFullBuffer, .{ &bus, &attempting, &completed });
    while (entered.load(.acquire) != handlers.len or !attempting.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    const completed_while_full = completed.load(.acquire);
    gate.store(true, .release);
    producer.join();
    try bus.stop();

    try std.testing.expect(!completed_while_full);
    try First.expectRange(0, capacity + 1);
    try Second.expectRange(0, capacity + 1);
}

fn releaseWhenDraining(bus: *Bus, gate: *std.atomic.Value(bool)) void {
    while (bus.state.load(.acquire) != .draining) std.Thread.yield() catch {};
    gate.store(true, .release);
}

test "stop drains queued events from paused handlers and restart preserves sequences" {
    First.reset();
    Second.reset();
    var gate = std.atomic.Value(bool).init(false);
    var entered = std.atomic.Value(usize).init(0);
    First.gate = &gate;
    Second.gate = &gate;
    First.entered = &entered;
    Second.entered = &entered;

    var bus = try Bus.init(std.testing.allocator, capacity);
    defer bus.deinit();
    try bus.start();

    const producer = try std.Thread.spawn(.{}, publish, .{ &bus, @as(usize, 0), capacity });
    producer.join();
    while (entered.load(.acquire) != handlers.len) std.Thread.yield() catch {};

    const releaser = try std.Thread.spawn(.{}, releaseWhenDraining, .{ &bus, &gate });
    try bus.stop();
    releaser.join();
    try First.expectRange(0, capacity);
    try Second.expectRange(0, capacity);

    // After stopping, the next production must reuse slots without replaying
    // events from the previous run.
    First.entered = null;
    Second.entered = null;
    try bus.start();
    const next_producer = try std.Thread.spawn(.{}, publish, .{ &bus, capacity, capacity });
    next_producer.join();
    try bus.stop();
    try First.expectRange(0, 2 * capacity);
    try Second.expectRange(0, 2 * capacity);
}
