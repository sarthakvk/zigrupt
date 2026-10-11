//! Single-producer broadcast, wraparound, backpressure, draining, and restart tests.

const std = @import("std");
const EventBus = @import("zigrupt").EventBus;
const EventHandler = @import("zigrupt").EventHandler;
const waiting_strategy = @import("zigrupt").waiting_strategy;
const Gate = @import("support/synchronization.zig").Gate;
const Counter = @import("support/synchronization.zig").Counter;
const Recorder = @import("support/utils.zig").Recorder;
const releaseWhenDraining = @import("support/utils.zig").releaseWhenDraining;

test "single producer tests" {
    const allocator = std.testing.allocator;

    // Separate recorder IDs make this a broadcast check, not a shared delivery count.
    const recorders = [_]type{ Recorder(2, event_count), Recorder(3, event_count), Recorder(4, event_count), Recorder(5, event_count) };
    const handlers: [4]EventHandler(usize) = .{
        recorders[0].handle,
        recorders[1].handle,
        recorders[2].handle,
        recorders[3].handle,
    };
    inline for (recorders) |recorder| recorder.reset();

    var bus = try EventBus(
        usize,
        false,
        &handlers,
        waiting_strategy.BusySpin,
        waiting_strategy.BusySpin,
    ).init(allocator, 8, 1);
    defer bus.deinit();

    try std.testing.expect(bus.state.load(.acquire) == .idle);

    try bus.start();

    try std.testing.expect(bus.state.load(.acquire) == .running);

    // Ten events exceed the eight-slot ring; every handler must see the full stream.
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

const First = Recorder(0, event_count);
const Second = Recorder(1, event_count);
const concurrent_handlers = [_]EventHandler(usize){ First.handle, Second.handle };
const Bus = EventBus(
    usize,
    false,
    &concurrent_handlers,
    waiting_strategy.BusySpin,
    waiting_strategy.BusySpin,
);

/// Publishes `len` consecutive values from `start`, waiting for slot reuse outside the bus.
///
/// Values must match sequence minus one, including after restart. This helper keeps
/// order and drain scenarios separate from the bus's own full-buffer waiting path.
fn publish(bus: *Bus, start: usize, len: usize) void {
    for (start..start + len) |value| {
        // The full-buffer test bypasses this helper to exercise the bus's own wait.
        if (value >= capacity) {
            for (concurrent_handlers, 0..) |_, consumer_id| {
                // The previous occupant is sequence value + 1 - capacity. A next-unread
                // cursor must be strictly past it before the producer can overwrite it.
                while (bus.sequencer.consumerSequence(consumer_id, .acquire) <= value + 1 - capacity) {
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
    var bus = try Bus.init(std.testing.allocator, capacity, 1);
    defer bus.deinit();

    try bus.start();
    const producer = try std.Thread.spawn(.{}, publish, .{ &bus, @as(usize, 0), event_count });
    producer.join(); // No production is in flight when stop begins.
    try bus.stop();

    try First.expectRange(0, event_count);
    try Second.expectRange(0, event_count);
}

/// Fills the ring, signals `attempting` before one extra publication, then increments `completed`.
fn publishPastFullBuffer(
    bus: *Bus,
    attempting: *Gate,
    completed: *Counter,
) void {
    for (0..capacity) |value| bus.produce(value) catch unreachable;
    // Signal before the extra publication, which cannot finish while handlers are paused.
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

    var bus = try Bus.init(std.testing.allocator, capacity, 1);
    defer bus.deinit();
    try bus.start();

    var attempting: Gate = .{};
    var completed: Counter = .{};
    const producer = try std.Thread.spawn(.{}, publishPastFullBuffer, .{ &bus, &attempting, &completed });
    entered.waitFor(concurrent_handlers.len);
    attempting.wait();

    // `attempting` marks intent before produce(), not arrival in its capacity wait.
    // The handler gate nevertheless keeps the ring full throughout this snapshot.
    const completed_while_full = completed.get();
    gate.open();
    producer.join();
    try bus.stop();

    try std.testing.expectEqual(0, completed_while_full);
    try First.expectRange(0, capacity + 1);
    try Second.expectRange(0, capacity + 1);
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

    var bus = try Bus.init(std.testing.allocator, capacity, 1);
    defer bus.deinit();
    try bus.start();

    const producer = try std.Thread.spawn(.{}, publish, .{ &bus, @as(usize, 0), capacity });
    producer.join();
    entered.waitFor(concurrent_handlers.len);

    // Producers have finished, but neither handler has acknowledged its first event.
    // Release only after stop enters draining so queued delivery exercises that phase.
    const releaser = try std.Thread.spawn(.{}, releaseWhenDraining, .{ &bus, &gate });
    try bus.stop();
    releaser.join();
    try First.expectRange(0, capacity);
    try Second.expectRange(0, capacity);

    // Keep both recordings and sequence progress across restart: the final range
    // catches replay as well as loss. Disable the one-time pause for the second run.
    First.entered = null;
    Second.entered = null;
    try bus.start();
    const next_producer = try std.Thread.spawn(.{}, publish, .{ &bus, capacity, capacity });
    next_producer.join();
    try bus.stop();
    try First.expectRange(0, 2 * capacity);
    try Second.expectRange(0, 2 * capacity);
}
