const std = @import("std");
const RingBufferEventBus = @import("zigrupt").EventBus;
const waiting_strategy = @import("zigrupt").waiting_strategy;
const Gate = @import("support/synchronization.zig").Gate;
const Counter = @import("support/synchronization.zig").Counter;

test "MultiProducer Ring buffer init" {
    const allocator = std.testing.allocator;

    const handlers = [_]*const fn (usize) void{
        Recorder(9).handle,
    };

    var eb = try RingBufferEventBus(
        usize,
        true,
        &handlers,
        waiting_strategy.BusySpin,
        waiting_strategy.BusySpin,
    ).init(allocator, 1024);
    defer eb.deinit();

    try std.testing.expectError(error.IncorrectBufferSize, RingBufferEventBus(
        usize,
        true,
        &handlers,
        waiting_strategy.BusySpin,
        waiting_strategy.BusySpin,
    ).init(allocator, 120));
}

test "MultiProducer DuplicateStart" {
    const allocator = std.testing.allocator;

    const handlers = [_]*const fn (usize) void{
        Recorder(9).handle,
    };

    var eb = try RingBufferEventBus(
        usize,
        true,
        &handlers,
        waiting_strategy.BusySpin,
        waiting_strategy.BusySpin,
    ).init(allocator, 1024);
    defer eb.deinit();

    try eb.start();
    defer eb.stop() catch {};

    try std.testing.expectError(error.BusRunning, eb.start());
}

test "MultiProducer start and stop require lifecycle owner" {
    const allocator = std.testing.allocator;
    const handlers = [_]*const fn (usize) void{
        Recorder(9).handle,
    };

    var bus = try RingBufferEventBus(
        usize,
        true,
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

const capacity = 8;
const producer_count = 4;
const events_per_producer = 128;
const event_count = producer_count * events_per_producer;

/// Each id gives a handler its own recording state. Only that handler writes it;
/// the test reads the recorded values after stop() has joined the handlers.
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
            // Paused-handler tests stop at the first event, before the bus can
            // advance this consumer's sequence. Signal once per handler, not
            // per event, so `entered` counts handlers that reached the gate.
            if (count == 0) {
                if (entered) |signal| {
                    signal.increment();
                    gate.?.wait();
                }
            }
            // Count excess deliveries so assertions fail without overrunning storage.
            if (count < values.len) values[count] = value;
            count += 1;
        }

        fn expectRange(start: usize, len: usize) !void {
            try std.testing.expectEqual(len, count);
            for (values[0..len], start..) |value, expected| {
                try std.testing.expectEqual(expected, value);
            }
        }

        fn expectProduced(start: usize, len: usize) !void {
            try std.testing.expectEqual(producer_count * len, count);
            var next: [producer_count]usize = @splat(start);
            // Each producer uses a disjoint value range encoding its id and offset.
            for (values[0..count]) |value| {
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
    };
}

const First = Recorder(0);
const Second = Recorder(1);
const concurrent_handlers = [_]*const fn (usize) void{ First.handle, Second.handle };
const Bus = RingBufferEventBus(
    usize,
    true,
    &concurrent_handlers,
    waiting_strategy.BusySpin,
    waiting_strategy.BusySpin,
);

const Producers = struct {
    threads: [producer_count]std.Thread = undefined,
    thread_count: usize = 0,
    ready: Counter = .{},
    gate: Gate = .{},
    cancelled: bool = false, // Written before opening the gate, read after waiting.
    completed: Counter = .{},

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

    fn join(self: *Producers) void {
        for (self.threads[0..self.thread_count]) |thread| thread.join();
        self.thread_count = 0;
    }
};

fn expectProduced(start: usize, len: usize) !void {
    try First.expectProduced(start, len);
    try Second.expectProduced(start, len);
    // Every handler must observe the same global sequence, whatever its order.
    try std.testing.expectEqualSlices(usize, First.values[0..First.count], Second.values[0..Second.count]);
}

test "MultiProducer concurrent producers deliver exactly once across wraps" {
    // Include fewer slots than producers, so outstanding claims span wraps too.
    for ([_]usize{ 1, 2, capacity, 64 }) |buffer_size| {
        First.reset();
        Second.reset();
        var bus = try Bus.init(std.testing.allocator, buffer_size);
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
        try std.testing.expectEqual(event_count + 1, bus.cursor.value.load(.acquire));
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

    var bus = try Bus.init(std.testing.allocator, capacity);
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
    // Wait for actual claims, not just a signal sent before calling produce.
    // Sequences start at 1, and the cursor points to the next unclaimed sequence.
    while (bus.cursor.value.load(.acquire) < capacity + producer_count + 1) std.Thread.yield() catch {};
    const completed_while_full = producers.completed.get();

    // Advancing only the first handler must not free slots still held by the second.
    first_gate.open();
    while (bus.consumer_seq[0].value.load(.acquire) < capacity + 1) std.Thread.yield() catch {};
    const completed_with_slow_handler = producers.completed.get();
    const slow_handler_sequence = bus.consumer_seq[1].value.load(.acquire);

    second_gate.open();
    producers.join();
    try bus.stop();

    try std.testing.expectEqual(0, completed_while_full);
    try std.testing.expectEqual(0, completed_with_slow_handler);
    try std.testing.expectEqual(1, slow_handler_sequence);
    try std.testing.expectEqual(producer_count, producers.completed.get());
    try expectProduced(0, initial_per_producer + 1);
}

// Hold one producer inside its wait after it has claimed a sequence. Another
// producer can then publish a later sequence first, leaving a publication gap.
const PausedPublisher = struct {
    threadlocal var paused: bool = false;
    var entered: Gate = .{};
    var released: Gate = .{};

    pub fn wait() void {
        if (paused) {
            entered.open();
            released.wait();
        }
        std.Thread.yield() catch {};
    }

    fn publish(bus: *GapBus, value: usize, pause: bool) void {
        paused = pause;
        bus.produce(value) catch unreachable;
    }
};

const GapBus = RingBufferEventBus(
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

    var bus = try GapBus.init(std.testing.allocator, capacity);
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

        for (bus.consumer_seq, &sequences_at_gap) |*consumer, *sequence| {
            while (consumer.value.load(.acquire) < capacity + 1) std.Thread.yield() catch {};
            sequence.* = consumer.value.load(.acquire);
        }
        earlier_publication = bus.buffer_seq[(capacity + 1) & bus.mask].load(.acquire);
        later_publication = bus.buffer_seq[(capacity + 2) & bus.mask].load(.acquire);
    }
    try bus.stop();

    try std.testing.expectEqual(1, earlier_publication); // Still the previous lap's publication.
    try std.testing.expectEqual(capacity + 2, later_publication);
    for (sequences_at_gap) |sequence| try std.testing.expectEqual(capacity + 1, sequence);
    try First.expectRange(0, capacity + 2);
    try Second.expectRange(0, capacity + 2);
}

// stop() blocks on the paused handlers, so another thread releases them only
// after draining begins. This ensures stop(), not normal consumption, drains the queue.
fn releaseWhenDraining(bus: *Bus, gate: *Gate) void {
    while (bus.state.load(.acquire) != .draining) std.Thread.yield() catch {};
    gate.open();
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

    var bus = try Bus.init(std.testing.allocator, capacity);
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

    const releaser = try std.Thread.spawn(.{}, releaseWhenDraining, .{ &bus, &gate });
    try bus.stop();
    releaser.join();
    try expectProduced(0, batch_per_producer);
    try std.testing.expectEqual(capacity + 1, bus.cursor.value.load(.acquire));

    // Keep the recorded events and sequences to detect replays after restart.
    First.entered = null;
    Second.entered = null;
    try bus.start();
    var next_producers: Producers = .{};
    try next_producers.start(&bus, batch_per_producer, batch_per_producer);
    next_producers.join();
    try bus.stop();
    try std.testing.expectEqual(2 * capacity + 1, bus.cursor.value.load(.acquire));
    try expectProduced(0, 2 * batch_per_producer);
}
