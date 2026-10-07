const std = @import("std");
const RingBufferEventBus = @import("zigrupt").EventBus;
const waiting_strategy = @import("zigrupt").waiting_strategy;
const Gate = @import("support/synchronization.zig").Gate;
const Counter = @import("support/synchronization.zig").Counter;

test "Ring buffer init" {
    const allocator = std.testing.allocator;

    const handlers = [_]*const fn (usize) void{
        Recorder(9).handle,
    };

    var eb = try RingBufferEventBus(
        usize,
        false,
        &handlers,
        waiting_strategy.BusySpin,
        waiting_strategy.BusySpin,
    ).init(allocator, 1024);
    defer eb.deinit();

    try std.testing.expectError(error.IncorrectBufferSize, RingBufferEventBus(
        usize,
        false,
        &handlers,
        waiting_strategy.BusySpin,
        waiting_strategy.BusySpin,
    ).init(allocator, 120));
}

test "DuplicateStart" {
    const allocator = std.testing.allocator;

    const handlers = [_]*const fn (usize) void{
        Recorder(9).handle,
    };

    var eb = try RingBufferEventBus(
        usize,
        false,
        &handlers,
        waiting_strategy.BusySpin,
        waiting_strategy.BusySpin,
    ).init(allocator, 1024);
    defer eb.deinit();

    try eb.start();
    defer eb.stop() catch {};

    try std.testing.expectError(error.BusRunning, eb.start());
}

test "start and stop require lifecycle owner" {
    const allocator = std.testing.allocator;
    const handlers = [_]*const fn (usize) void{
        Recorder(9).handle,
    };

    var bus = try RingBufferEventBus(
        usize,
        false,
        &handlers,
        waiting_strategy.BusySpin,
        waiting_strategy.BusySpin,
    ).init(allocator, 1024);
    defer bus.deinit();

    const worker = struct {
        fn run(eb: *@TypeOf(bus), result: *?anyerror, start_bus: bool) void {
            const operation = if (start_bus) eb.start() else eb.stop();
            operation catch |err| {
                result.* = err;
            };
        }
    };

    var result: ?anyerror = null;
    var thread = try std.Thread.spawn(.{}, worker.run, .{ &bus, &result, true });
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, error.NotLifecycleOwner), result);

    try bus.start();
    defer bus.stop() catch {};

    result = null;
    thread = try std.Thread.spawn(.{}, worker.run, .{ &bus, &result, false });
    thread.join();
    try std.testing.expectEqual(@as(?anyerror, error.NotLifecycleOwner), result);
}

test "single producer tests" {
    const allocator = std.testing.allocator;

    const recorders = [_]type{ Recorder(2), Recorder(3), Recorder(4), Recorder(5) };
    const handlers: [4]*const fn (usize) void = .{
        recorders[0].handle,
        recorders[1].handle,
        recorders[2].handle,
        recorders[3].handle,
    };
    inline for (recorders) |recorder| recorder.reset();

    var bus = try RingBufferEventBus(
        usize,
        false,
        &handlers,
        waiting_strategy.BusySpin,
        waiting_strategy.BusySpin,
    ).init(allocator, 8);
    defer bus.deinit();

    try std.testing.expect(bus.state.load(.acquire) == .idle);

    try bus.start();

    try std.testing.expect(bus.state.load(.acquire) == .running);

    for (0..10) |i| {
        try bus.produce(i);
    }

    try std.testing.expect(bus.state.load(.acquire) == .running);
    try bus.stop();

    try std.testing.expect(bus.state.load(.acquire) == .idle);

    inline for (recorders) |recorder| try recorder.expectRange(0, 10);
}

const capacity = 8;
const event_count = 512;

fn Recorder(comptime id: usize) type {
    return struct {
        var values: [event_count]usize = undefined;
        var count: usize = 0;
        var gate: ?*Gate = null;
        var entered: ?*Counter = null;
        var unique_id = id;

        fn reset() void {
            count = 0;
            gate = null;
            entered = null;
        }

        fn handle(value: usize) void {
            if (count == 0) {
                if (entered) |signal| {
                    signal.increment();
                    gate.?.wait();
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
const concurrent_handlers = [_]*const fn (usize) void{ First.handle, Second.handle };
const Bus = RingBufferEventBus(
    usize,
    false,
    &concurrent_handlers,
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
    attempting: *Gate,
    completed: *Counter,
) void {
    for (0..capacity) |value| bus.produce(value) catch unreachable;
    attempting.open();
    bus.produce(capacity) catch unreachable;
    completed.increment();
}

test "publisher waits for a full buffer until handlers advance" {
    First.reset();
    Second.reset();
    var gate: Gate = .{};
    var entered: Counter = .{};
    First.gate = &gate;
    Second.gate = &gate;
    First.entered = &entered;
    Second.entered = &entered;

    var bus = try Bus.init(std.testing.allocator, capacity);
    defer bus.deinit();
    try bus.start();

    var attempting: Gate = .{};
    var completed: Counter = .{};
    const producer = try std.Thread.spawn(.{}, publishPastFullBuffer, .{ &bus, &attempting, &completed });
    entered.waitFor(concurrent_handlers.len);
    attempting.wait();

    const completed_while_full = completed.get();
    gate.open();
    producer.join();
    try bus.stop();

    try std.testing.expectEqual(0, completed_while_full);
    try First.expectRange(0, capacity + 1);
    try Second.expectRange(0, capacity + 1);
}

fn releaseWhenDraining(bus: *Bus, gate: *Gate) void {
    while (bus.state.load(.acquire) != .draining) std.Thread.yield() catch {};
    gate.open();
}

test "stop drains queued events from paused handlers and restart preserves sequences" {
    First.reset();
    Second.reset();
    var gate: Gate = .{};
    var entered: Counter = .{};
    First.gate = &gate;
    Second.gate = &gate;
    First.entered = &entered;
    Second.entered = &entered;

    var bus = try Bus.init(std.testing.allocator, capacity);
    defer bus.deinit();
    try bus.start();

    const producer = try std.Thread.spawn(.{}, publish, .{ &bus, @as(usize, 0), capacity });
    producer.join();
    entered.waitFor(concurrent_handlers.len);

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
