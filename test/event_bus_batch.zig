//! Batch sizing, wrap boundaries, partial consumption, and publication-gap tests in both bus phases.

const std = @import("std");
const EventBus = @import("zigrupt").EventBus;
const EventHandler = @import("zigrupt").EventHandler;
const RingBuffer = @import("zigrupt").RingBuffer;
const waiting_strategy = @import("zigrupt").waiting_strategy;
const Gate = @import("support/synchronization.zig").Gate;
const Counter = @import("support/synchronization.zig").Counter;
const releaseWhenDraining = @import("support/utils.zig").releaseWhenDraining;

const capacity = 8;

/// Creates an isolated recorder for `id` with configurable partial consumption and one-time pausing.
///
/// Distinct IDs keep each handler's observations independent. Configure and inspect
/// only before startup, after acquiring acknowledgement of every queued event with
/// no new publications, or after joining handlers.
///
/// The first paused call is synchronization only and is excluded from the recording.
/// `lengths` and `first_values` describe offered batches; `values` stores only consumed events.
fn BatchRecorder(comptime id: usize) type {
    return struct {
        var unique_id = id;
        // Acquiring acknowledgement of all queued events permits setup changes before the next publication.
        var gate: *Gate = undefined;
        var entered: *Counter = undefined;
        var paused: bool = false;
        var consume_limit: usize = capacity;
        var return_zero_once: bool = false;
        var lengths: [32]usize = undefined;
        var first_values: [32]usize = undefined;
        var calls: usize = 0;
        var values: [32]usize = undefined;
        var count: usize = 0;

        /// Clears recording state and installs first-call synchronization.
        ///
        /// No callback may be active or new events published until reset completes.
        fn reset(release: *Gate, ready: *Counter) void {
            gate = release;
            entered = ready;
            paused = false;
            consume_limit = capacity;
            return_zero_once = false;
            calls = 0;
            count = 0;
        }

        /// Pauses and returns zero on its first call, then records batches and their consumed prefixes.
        fn handle(events: []const usize) usize {
            if (!paused) {
                paused = true;
                entered.increment();
                gate.wait();
                // Retry the first event after the entire test queue is ready.
                // Releasing during stop forces that retry into the drain loop.
                return 0;
            }
            const consumed = if (return_zero_once and calls == 0) 0 else @min(consume_limit, events.len);
            if (calls < lengths.len) {
                lengths[calls] = events.len;
                first_values[calls] = events[0];
            }
            calls += 1;
            for (events[0..consumed]) |value| {
                if (count < values.len) values[count] = value;
                count += 1;
            }
            return consumed;
        }

        /// Asserts callback batch lengths after the initial paused call match `expected` exactly.
        fn expectBatches(expected: []const usize) !void {
            try std.testing.expectEqual(expected.len, calls);
            try std.testing.expectEqualSlices(usize, expected, lengths[0..calls]);
        }

        /// Asserts exactly `len` consumed values in consecutive order beginning at `start`.
        fn expectRange(start: usize, len: usize) !void {
            try std.testing.expectEqual(len, count);
            for (values[0..count], start..) |value, expected| {
                try std.testing.expectEqual(expected, value);
            }
        }
    };
}

const First = BatchRecorder(0);
const Second = BatchRecorder(1);
const handlers = [_]EventHandler(usize){ First.handle, Second.handle };

/// Creates a bus type for the chosen producer mode.
fn Bus(comptime multi_producer: bool) type {
    return EventBus(usize, multi_producer, &handlers, waiting_strategy.BusySpin, waiting_strategy.BusySpin);
}

/// Releases handlers and waits for every next-unread cursor while keeping the bus running.
fn consume(bus: anytype, gate: *Gate, next_sequence: usize) !void {
    gate.open();
    for (0..bus.sequencer.consumer_seq.len) |consumer_id| {
        while (bus.sequencer.consumerSequence(consumer_id, .acquire) < next_sequence) std.Thread.yield() catch {};
    }
}

/// Releases handlers during draining, or waits for `next_sequence` while running, then stops the bus.
///
/// Propagates release-thread spawn and bus-stop errors.
///
/// In the running case, wait for every next-unread cursor to reach the target before
/// stopping, so the expected callbacks cannot be deferred to draining. In the draining
/// case, keep handlers held until stop changes state. No producer calls may be in flight.
fn finish(bus: anytype, gate: *Gate, draining: bool, next_sequence: usize) !void {
    if (draining) {
        const releaser = try std.Thread.spawn(.{}, releaseWhenDraining, .{ bus, gate });
        defer releaser.join();
        try bus.stop();
    } else {
        try consume(bus, gate, next_sequence);
        try bus.stop();
    }
}

test "batch size must be nonzero and no larger than capacity" {
    inline for (.{ false, true }) |multi_producer| {
        for ([_]usize{ 1, capacity }) |buffer_size| {
            try std.testing.expectError(error.IncorrectBatchSize, Bus(multi_producer).init(std.testing.allocator, buffer_size, 0));
            try std.testing.expectError(error.IncorrectBatchSize, Bus(multi_producer).init(std.testing.allocator, buffer_size, buffer_size + 1));
            for (1..buffer_size + 1) |max_batch| {
                var bus = try Bus(multi_producer).init(std.testing.allocator, buffer_size, max_batch);
                defer bus.deinit();
                try std.testing.expectEqual(max_batch, bus.max_batch_size);
            }
        }
    }
}

test "running and draining batches respect size, wrap and the end of the queue" {
    // Batch limit, publication count, and expected callback lengths for one scenario.
    // Starting at index one leaves seven contiguous slots: eight queued events split
    // at the ring boundary even when max_batch permits all eight in a single call.
    const Case = struct { max_batch: usize, events: usize, lengths: []const usize };
    const cases = [_]Case{
        .{ .max_batch = 1, .events = 8, .lengths = &.{ 1, 1, 1, 1, 1, 1, 1, 1 } },
        .{ .max_batch = 3, .events = 8, .lengths = &.{ 3, 3, 1, 1 } },
        .{ .max_batch = 8, .events = 8, .lengths = &.{ 7, 1 } },
        .{ .max_batch = 3, .events = 5, .lengths = &.{ 3, 2 } },
        .{ .max_batch = 8, .events = 5, .lengths = &.{5} },
    };
    inline for (.{ false, true }) |multi_producer| {
        for ([_]bool{ false, true }) |draining| {
            for (cases) |case| {
                var bus = try Bus(multi_producer).init(std.testing.allocator, capacity, case.max_batch);
                defer bus.deinit();
                // A bad batch should report extra deliveries, not read undefined data.
                for (0..capacity) |sequence| bus.buffer.save(sequence, std.math.maxInt(usize));
                var gate: Gate = .{};
                var entered: Counter = .{};
                First.reset(&gate, &entered);
                Second.reset(&gate, &entered);
                try bus.start();
                defer {
                    gate.open();
                    bus.stop() catch {};
                }
                // Neither callback acknowledges the first event while gated, so the
                // remaining publications cannot be consumed before the queue is complete.
                try bus.produce(1);
                entered.waitFor(handlers.len);
                for (2..case.events + 1) |value| try bus.produce(value);
                try finish(&bus, &gate, draining, case.events + 1);

                inline for (.{ First, Second }) |recorder| {
                    try recorder.expectBatches(case.lengths);
                    try recorder.expectRange(1, case.events);
                }
                for (handlers, 0..) |_, consumer_id| {
                    try std.testing.expectEqual(case.events + 1, bus.sequencer.consumerSequence(consumer_id, .acquire));
                }
            }
        }
    }
}

test "partial and zero consumption retry the unconsumed suffix independently per handler" {
    inline for (.{ false, true }) |multi_producer| {
        for ([_]bool{ false, true }) |draining| {
            var bus = try Bus(multi_producer).init(std.testing.allocator, capacity, 5);
            defer bus.deinit();
            // Keep the bus running across laps so reused slots cannot replay old publications.
            var gates: [2]Gate = .{ .{}, .{} };
            var entered: [2]Counter = .{ .{}, .{} };
            defer {
                for (&gates) |*gate| gate.open();
                bus.stop() catch {};
            }
            for (0..2) |lap| {
                const gate = &gates[lap];
                First.reset(gate, &entered[lap]);
                Second.reset(gate, &entered[lap]);
                Second.consume_limit = 2;
                Second.return_zero_once = true;
                const start = lap * capacity + 1;
                if (lap == 0) try bus.start();
                try bus.produce(start);
                entered[lap].waitFor(handlers.len);
                for (start + 1..start + capacity) |value| try bus.produce(value);
                if (lap == 0) {
                    try consume(&bus, gate, start + capacity);
                } else {
                    try finish(&bus, gate, draining, start + capacity);
                }

                // First consumes whole offers: 5 + 2 up to the boundary, then 1 after wrap.
                // Second first consumes zero, then at most two: its offered lengths are
                // 5 (zero), 5, 5, 3, 1 before wrap, and 1 after wrap. Only acknowledged
                // prefixes advance its cursor; the other handler's progress is independent.
                try First.expectBatches(&.{ 5, 2, 1 });
                try Second.expectBatches(&.{ 5, 5, 5, 3, 1, 1 });
                const expected_first = [_]usize{ start, start, start + 2, start + 4, start + 6, start + 7 };
                try std.testing.expectEqualSlices(usize, &expected_first, Second.first_values[0..Second.calls]);
                try First.expectRange(start, capacity);
                try Second.expectRange(start, capacity);
                for (handlers, 0..) |_, consumer_id| {
                    try std.testing.expectEqual(start + capacity, bus.sequencer.consumerSequence(consumer_id, .acquire));
                }
            }
        }
    }
}

test "running and draining callbacks borrow ring storage across wraps and slot reuse" {
    // Acquire acknowledgement of each lap before inspecting or resetting handler-owned observations.
    const BorrowedBatch = struct {
        var ring: *const RingBuffer(usize) = undefined;
        var gate: *Gate = undefined;
        var entered: *Counter = undefined;
        var paused: bool = false;
        var borrowed: bool = true;
        var calls: usize = 0;
        var count: usize = 0;

        /// Checks storage identity; test event values are their publication sequences.
        fn handle(events: []const usize) usize {
            // Equal values alone could come from a copy; equal addresses establish
            // that the callback borrows the slot for this exact publication sequence.
            borrowed = borrowed and &events[0] == ring.get(events[0]);
            calls += 1;
            if (!paused) {
                paused = true;
                entered.increment();
                gate.wait();
                // Keep the first event unread so its retry checks borrowing in the chosen phase.
                return 0;
            }
            count += events.len;
            return events.len;
        }
    };
    inline for (.{ false, true }) |multi_producer| {
        for ([_]bool{ false, true }) |draining| {
            const BorrowedBus = EventBus(usize, multi_producer, &.{BorrowedBatch.handle}, waiting_strategy.BusySpin, waiting_strategy.BusySpin);
            var bus = try BorrowedBus.init(std.testing.allocator, capacity, capacity);
            defer bus.deinit();
            BorrowedBatch.ring = &bus.buffer;

            var gates: [2]Gate = .{ .{}, .{} };
            var entered: [2]Counter = .{ .{}, .{} };
            defer {
                for (&gates) |*gate| gate.open();
                bus.stop() catch {};
            }
            for (0..2) |lap| {
                const gate = &gates[lap];
                BorrowedBatch.gate = gate;
                BorrowedBatch.entered = &entered[lap];
                BorrowedBatch.paused = false;
                BorrowedBatch.borrowed = true;
                BorrowedBatch.calls = 0;
                BorrowedBatch.count = 0;
                const start = lap * capacity + 1;
                if (lap == 0) try bus.start();
                try bus.produce(start);
                entered[lap].waitFor(1);
                for (start + 1..start + capacity) |value| try bus.produce(value);
                if (lap == 0) {
                    try consume(&bus, gate, start + capacity);
                } else {
                    try finish(&bus, gate, draining, start + capacity);
                }

                try std.testing.expect(BorrowedBatch.borrowed);
                // One paused call plus the seven-slot prefix and the one-slot wrapped tail.
                try std.testing.expectEqual(3, BorrowedBatch.calls);
                try std.testing.expectEqual(capacity, BorrowedBatch.count);
            }
        }
    }
}

test "running and draining batches stop at unpublished or stale claims before later publications" {
    for ([_]bool{ false, true }) |draining| {
        for ([_]bool{ false, true }) |stale| {
            var bus = try Bus(true).init(std.testing.allocator, capacity, capacity);
            defer bus.deinit();
            for (0..capacity) |sequence| bus.buffer.save(sequence, std.math.maxInt(usize));
            var warmup_gate: Gate = .{};
            var warmup_entered: Counter = .{};
            var gate: Gate = .{};
            var entered: Counter = .{};
            defer {
                warmup_gate.open();
                gate.open();
                bus.stop() catch {};
            }
            First.reset(if (stale) &warmup_gate else &gate, if (stale) &warmup_entered else &entered);
            Second.reset(if (stale) &warmup_gate else &gate, if (stale) &warmup_entered else &entered);
            try bus.start();
            // Warm up a complete lap without stopping when testing stale markers.
            // Otherwise untouched slots contain zero; both cases must hide later publications.
            if (stale) {
                try bus.produce(1);
                warmup_entered.waitFor(handlers.len);
                for (2..capacity + 1) |value| try bus.produce(value);
                try consume(&bus, &warmup_gate, capacity + 1);
                First.reset(&gate, &entered);
                Second.reset(&gate, &entered);
            }

            const start = bus.sequencer.nextClaimSequence();
            try bus.produce(start);
            entered.waitFor(handlers.len);
            try bus.produce(start + 1);
            // Model a producer that claimed but never published. No producer is
            // actually in flight when stop() runs; the gap is intentionally retained.
            const gap = bus.sequencer.claim();
            try std.testing.expectEqual(start + 2, gap);
            for (gap + 1..gap + 4) |value| try bus.produce(value);
            // On the second lap the missing sequence is 11, whose slot still names 3.
            // A nonzero marker is insufficient: it must match the expected sequence.
            try std.testing.expectEqual(if (stale) @as(usize, 3) else 0, bus.sequencer.buffer_seq[gap & bus.sequencer.mask].load(.acquire));
            try finish(&bus, &gate, draining, gap);

            inline for (.{ First, Second }) |recorder| {
                try recorder.expectBatches(&.{2});
                try recorder.expectRange(start, 2);
            }
            for (handlers, 0..) |_, consumer_id| {
                try std.testing.expectEqual(gap, bus.sequencer.consumerSequence(consumer_id, .acquire));
            }
            // Claims extend past the gap, but consumption and draining must stop at it.
            try std.testing.expectEqual(gap + 4, bus.sequencer.nextClaimSequence());
        }
    }
}
