//! Concurrent-producer ordering, backpressure, publication gaps, draining, and restart tests.
//!
//! Values encode producer ID and per-producer offset, not publication sequence. Global
//! producer interleaving is unspecified, but both handlers must observe the same order.
//! Gates hold the relevant producers or handlers in place; cursor/marker reads establish
//! bus progress without sleeps. The test thread owns lifecycle and joins producers before stop.

const std = @import("std");
const EventBus = @import("zigrupt").EventBus;
const EventHandler = @import("zigrupt").EventHandler;
const waiting_strategy = @import("zigrupt").waiting_strategy;
const Gate = @import("support/synchronization.zig").Gate;
const Counter = @import("support/synchronization.zig").Counter;
const Recorder = @import("support/utils.zig").Recorder;
const releaseWhenDraining = @import("support/utils.zig").releaseWhenDraining;

const capacity = 8;
const producer_count = 4;
const events_per_producer = 128;
const event_count = producer_count * events_per_producer;

const First = Recorder(0, event_count);
const Second = Recorder(1, event_count);
const concurrent_handlers = [_]EventHandler(usize){ First.handle, Second.handle };
const Bus = EventBus(
    usize,
    true,
    &concurrent_handlers,
    waiting_strategy.BusySpin,
    waiting_strategy.BusySpin,
);

/// Producer thread group with a shared start gate and thread-safe completion tracking.
///
/// Each instance is used for one launch and must stay at a stable address through join.
/// The owner writes launch state before opening the gate; workers increment `completed`
/// only after their final produce call returns.
const Producers = struct {
    threads: [producer_count]std.Thread = undefined,
    thread_count: usize = 0,
    ready: Counter = .{},
    gate: Gate = .{},
    cancelled: bool = false, // Written before opening the gate, read after waiting.
    completed: Counter = .{},

    /// Spawns producers for `len` offsets from `start_offset`, releasing them once all are ready.
    ///
    /// On spawn failure, cancels and joins any started threads before propagating the error.
    fn start(self: *Producers, bus: *Bus, start_offset: usize, len: usize) !void {
        errdefer {
            // A partial spawn failure must release waiting producers without publishing.
            self.cancelled = true;
            self.gate.open();
            self.join();
        }
        for (0..producer_count) |producer_id| {
            self.threads[producer_id] = try std.Thread.spawn(.{}, publish, .{ self, bus, producer_id, start_offset, len });
            self.thread_count += 1;
        }
        // All producers must be ready before any of them starts claiming slots.
        self.ready.waitFor(producer_count);
        self.gate.open();
    }

    /// Waits for the start gate, then publishes values encoding the producer ID and offset.
    fn publish(self: *Producers, bus: *Bus, producer_id: usize, start_offset: usize, len: usize) void {
        self.ready.increment();
        self.gate.wait();
        if (self.cancelled) return;

        for (start_offset..start_offset + len) |offset| {
            // Slot ownership and backpressure belong to the bus, not the test.
            bus.produce(producer_id * events_per_producer + offset) catch unreachable;
        }
        self.completed.increment();
    }

    /// Joins all started producer threads; repeated calls are safe.
    fn join(self: *Producers) void {
        for (self.threads[0..self.thread_count]) |thread| thread.join();
        self.thread_count = 0;
    }
};

/// Asserts each producer's offsets arrive once in order, with identical interleaving for both handlers.
fn expectProduced(start: usize, len: usize) !void {
    inline for (.{ First, Second }) |recorder| {
        try std.testing.expectEqual(producer_count * len, recorder.count);
        var next: [producer_count]usize = @splat(start);
        // Each producer uses a disjoint value range encoding its id and offset.
        for (recorder.values[0..recorder.count]) |value| {
            const producer_id = value / events_per_producer;
            const offset = value % events_per_producer;
            try std.testing.expect(producer_id < producer_count);
            // Each producer's stream is ordered and delivered exactly once;
            // the interleaving between different producers is unspecified.
            try std.testing.expectEqual(next[producer_id], offset);
            next[producer_id] += 1;
        }
        for (next) |offset| try std.testing.expectEqual(start + len, offset);
    }
    // Every handler must observe the same global sequence, whatever its order.
    try std.testing.expectEqualSlices(usize, First.values[0..First.count], Second.values[0..Second.count]);
}

test "MultiProducer concurrent producers deliver exactly once across wraps" {
    // Include fewer slots than producers, so outstanding claims span wraps too.
    for ([_]usize{ 1, 2, capacity, 64 }) |buffer_size| {
        First.reset();
        Second.reset();
        var bus = try Bus.init(std.testing.allocator, buffer_size, 1);
        defer bus.deinit();

        try std.testing.expectEqual(.idle, bus.state.load(.acquire));
        try bus.start();
        defer bus.stop() catch {};

        var producers: Producers = .{};
        try producers.start(&bus, 0, events_per_producer);
        defer producers.join();
        producers.join(); // No production is in flight when stop begins.

        try std.testing.expectEqual(.running, bus.state.load(.acquire));
        try bus.stop();
        try std.testing.expectEqual(.idle, bus.state.load(.acquire));
        try std.testing.expectEqual(event_count + 1, bus.sequencer.nextClaimSequence());
        try expectProduced(0, events_per_producer);
    }
}

test "MultiProducer full buffer blocks all producers until the slowest handler advances" {
    First.reset();
    Second.reset();
    var first_gate: Gate = .{};
    var second_gate: Gate = .{};
    var entered: Counter = .{};
    First.gate = &first_gate;
    Second.gate = &second_gate;
    First.entered = &entered;
    Second.entered = &entered;

    var bus = try Bus.init(std.testing.allocator, capacity, 1);
    defer bus.deinit();
    try bus.start();
    defer {
        first_gate.open();
        second_gate.open();
        bus.stop() catch {};
    }

    const initial_per_producer = capacity / producer_count;
    for (0..producer_count) |producer_id| {
        for (0..initial_per_producer) |offset| {
            try bus.produce(producer_id * events_per_producer + offset);
        }
    }
    entered.waitFor(concurrent_handlers.len);

    var producers: Producers = .{};
    try producers.start(&bus, initial_per_producer, 1);
    defer {
        first_gate.open();
        second_gate.open();
        producers.join();
    }
    // Wait for actual claims, not just intent to publish. The cursor starts at one
    // and names the next unclaimed sequence, so this target proves every producer
    // reserved its extra sequence while both handlers still hold the first lap.
    while (bus.sequencer.nextClaimSequence() < capacity + producer_count + 1) std.Thread.yield() catch {};
    const completed_while_full = producers.completed.get();

    // Advancing only the first handler must not free slots still held by the second.
    first_gate.open();
    while (bus.sequencer.consumerSequence(0, .acquire) < capacity + 1) std.Thread.yield() catch {};
    const completed_with_slow_handler = producers.completed.get();
    const slow_handler_sequence = bus.sequencer.consumerSequence(1, .acquire);

    second_gate.open();
    producers.join();
    try bus.stop();

    try std.testing.expectEqual(0, completed_while_full);
    try std.testing.expectEqual(0, completed_with_slow_handler);
    try std.testing.expectEqual(1, slow_handler_sequence);
    try std.testing.expectEqual(producer_count, producers.completed.get());
    try expectProduced(0, initial_per_producer + 1);
}

/// Waiting strategy that holds one claimed sequence while another producer publishes past it.
///
/// Only threads with `paused` set block. Entering this wait proves that produce() has
/// already claimed a sequence and found its slot unsafe; releasing consumers alone
/// cannot resume that publisher until `released` also opens.
///
/// Reset the shared gates between tests, with no publisher threads active.
const PausedPublisher = struct {
    threadlocal var paused: bool = false;
    var entered: Gate = .{};
    var released: Gate = .{};

    /// Signals and blocks pause-enabled publishers until released, then yields the thread.
    pub fn wait() void {
        if (paused) {
            entered.open();
            released.wait();
        }
        std.Thread.yield() catch {};
    }

    /// Publishes one value with optional pausing on this thread's capacity waits.
    fn publish(bus: *GapBus, value: usize, pause: bool) void {
        paused = pause;
        bus.produce(value) catch unreachable;
    }
};

const GapBus = EventBus(
    usize,
    true,
    &concurrent_handlers,
    PausedPublisher,
    waiting_strategy.BusySpin,
);

test "MultiProducer handlers wait for an unpublished claim before consuming a later publication" {
    First.reset();
    Second.reset();
    PausedPublisher.entered = .{};
    PausedPublisher.released = .{};
    var gate: Gate = .{};
    var entered: Counter = .{};
    First.gate = &gate;
    Second.gate = &gate;
    First.entered = &entered;
    Second.entered = &entered;

    var bus = try GapBus.init(std.testing.allocator, capacity, 1);
    defer bus.deinit();
    try bus.start();
    defer {
        gate.open();
        bus.stop() catch {};
    }
    for (0..capacity) |value| try bus.produce(value);
    entered.waitFor(concurrent_handlers.len);

    var sequences_at_gap: [concurrent_handlers.len]usize = undefined;
    var earlier_publication: usize = undefined;
    var later_publication: usize = undefined;
    {
        // The full ring forces the earlier producer into the custom wait after it
        // claims sequence capacity + 1, making the publication gap deterministic.
        const earlier = try std.Thread.spawn(.{}, PausedPublisher.publish, .{ &bus, capacity, true });
        defer earlier.join();
        defer {
            gate.open();
            PausedPublisher.released.open();
        }
        PausedPublisher.entered.wait();

        const later = try std.Thread.spawn(.{}, PausedPublisher.publish, .{ &bus, capacity + 1, false });
        // Let consumers free slots, but keep the earlier producer paused so the
        // later publication leaves a gap that consumers must not skip.
        gate.open();
        later.join();

        for (&sequences_at_gap, 0..) |*sequence, consumer_id| {
            while (bus.sequencer.consumerSequence(consumer_id, .acquire) < capacity + 1) std.Thread.yield() catch {};
            sequence.* = bus.sequencer.consumerSequence(consumer_id, .acquire);
        }
        // Snapshot before releasing the earlier publisher: its slot still carries a
        // stale marker while the later slot is published. Cursors must stop at the gap.
        earlier_publication = bus.sequencer.buffer_seq[(capacity + 1) & bus.sequencer.mask].load(.acquire);
        later_publication = bus.sequencer.buffer_seq[(capacity + 2) & bus.sequencer.mask].load(.acquire);
    }
    try bus.stop();

    try std.testing.expectEqual(1, earlier_publication); // Still the previous lap's publication.
    try std.testing.expectEqual(capacity + 2, later_publication);
    for (sequences_at_gap) |sequence| try std.testing.expectEqual(capacity + 1, sequence);
    try First.expectRange(0, capacity + 2);
    try Second.expectRange(0, capacity + 2);
}

test "MultiProducer stop drains all producers and restart preserves sequences" {
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
    defer {
        gate.open();
        bus.stop() catch {};
    }

    const batch_per_producer = capacity / producer_count;
    var producers: Producers = .{};
    try producers.start(&bus, 0, batch_per_producer);
    producers.join();
    entered.waitFor(concurrent_handlers.len);

    // All producers are joined and the ring is full. Holding the first callbacks
    // until draining begins ensures stop, rather than normal running, delivers the queue.
    const releaser = try std.Thread.spawn(.{}, releaseWhenDraining, .{ &bus, &gate });
    try bus.stop();
    releaser.join();
    try expectProduced(0, batch_per_producer);
    try std.testing.expectEqual(capacity + 1, bus.sequencer.nextClaimSequence());

    // Keep the recorded events and sequences to detect replays after restart.
    // Resume each producer's offsets instead of beginning a new value range.
    First.entered = null;
    Second.entered = null;
    try bus.start();
    var next_producers: Producers = .{};
    try next_producers.start(&bus, batch_per_producer, batch_per_producer);
    next_producers.join();
    try bus.stop();
    try std.testing.expectEqual(2 * capacity + 1, bus.sequencer.nextClaimSequence());
    try expectProduced(0, 2 * batch_per_producer);
}
