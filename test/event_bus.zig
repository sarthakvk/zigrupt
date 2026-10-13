//! Initialization and lifecycle ownership checks for both producer modes.

const std = @import("std");
const EventBus = @import("zigrupt").EventBus;
const waiting_strategy = @import("zigrupt").waiting_strategy;
const Recorder = @import("support/utils.zig").Recorder;

// Lifecycle tests need a registered handler but never publish an accepted event.
const handler = Recorder(0, 1).handle;

test "EventBus init" {
    inline for (.{ false, true }) |multi_producer| {
        const Bus = EventBus(
            usize,
            multi_producer,
            waiting_strategy.BusySpin,
            waiting_strategy.BusySpin,
        );
        var bus = try Bus.init(std.testing.allocator, 1024, 1);
        defer bus.deinit();

        try std.testing.expectEqual(1, bus.max_batch_size);
        try std.testing.expectEqual(1024, bus.buffer.slice(0, 1024).len);
        // A failing allocator distinguishes validation from an attempted allocation.
        for ([_]usize{ 0, 3, 120 }) |buffer_size| {
            try std.testing.expectError(error.IncorrectBufferSize, Bus.init(std.testing.failing_allocator, buffer_size, 1));
        }
    }
}

test "EventBus init releases ring storage when later allocations fail" {
    inline for (.{ false, true }) |multi_producer| {
        const Check = struct {
            /// Exercises successful teardown and each injected allocation-failure path.
            fn initAndDeinit(allocator: std.mem.Allocator) !void {
                const Bus = EventBus(usize, multi_producer, waiting_strategy.BusySpin, waiting_strategy.BusySpin);
                var bus = try Bus.init(allocator, 8, 1);
                defer bus.deinit();
            }
        };
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.initAndDeinit, .{});
    }
}

test "start rejects a bus with no registered handlers and leaves it idle" {
    inline for (.{ false, true }) |multi_producer| {
        for ([_]usize{ 1, 8 }) |capacity| {
            const Bus = EventBus(usize, multi_producer, waiting_strategy.BusySpin, waiting_strategy.BusySpin);
            var bus = try Bus.init(std.testing.allocator, capacity, 1);
            defer bus.deinit();
            defer bus.stop() catch {};

            // Repeating the attempt checks that rejection leaves the bus reusable and
            // that a rejected publication never reserves a sequence.
            for (0..2) |_| {
                try std.testing.expectError(error.NoHandlersRegistered, bus.start());
                try std.testing.expectEqual(.idle, bus.state.load(.acquire));
                try std.testing.expectError(error.BusIdle, bus.produce(1));
                try std.testing.expectEqual(1, bus.sequencer.nextClaimSequence());
            }
        }
    }
}

test "DuplicateStart" {
    inline for (.{ false, true }) |multi_producer| {
        const Bus = EventBus(
            usize,
            multi_producer,
            waiting_strategy.BusySpin,
            waiting_strategy.BusySpin,
        );
        var bus = try Bus.init(std.testing.allocator, 1024, 1);
        defer bus.deinit();

        _ = try bus.registerEventHandler(handler);
        try bus.start();
        defer bus.stop() catch {};

        try std.testing.expectError(error.BusRunning, bus.start());
    }
}

test "stopped bus rejects restart, publication and repeated stop without changing sequences" {
    inline for (.{ false, true }) |multi_producer| {
        const Bus = EventBus(usize, multi_producer, waiting_strategy.BusySpin, waiting_strategy.BusySpin);
        var bus = try Bus.init(std.testing.allocator, 8, 1);
        defer bus.deinit();
        try bus.registerEventHandler(handler);
        try bus.start();
        defer bus.stop() catch {};
        try bus.stop();

        try std.testing.expectEqual(.stopped, bus.state.load(.acquire));
        for (0..2) |_| {
            try std.testing.expectError(error.BusStopped, bus.start());
            try std.testing.expectError(error.BusStopped, bus.produce(1));
            try std.testing.expectError(error.BusStopped, bus.stop());
            try std.testing.expectEqual(.stopped, bus.state.load(.acquire));
            try std.testing.expectEqual(1, bus.sequencer.nextClaimSequence());
            try std.testing.expectEqual(1, try bus.sequencer.consumerSequence(0, .acquire));
        }
    }
}

test "start and stop require lifecycle owner" {
    inline for (.{ false, true }) |multi_producer| {
        const Bus = EventBus(
            usize,
            multi_producer,
            waiting_strategy.BusySpin,
            waiting_strategy.BusySpin,
        );
        var bus = try Bus.init(std.testing.allocator, 1024, 1);
        defer bus.deinit();

        _ = try bus.registerEventHandler(handler);

        // Worker for attempting lifecycle operations outside the initializing thread.
        const worker = struct {
            /// Attempts start or stop and records any error.
            ///
            /// Read `result` after joining.
            fn run(eb: *Bus, result: *?anyerror, start_bus: bool) void {
                const operation = if (start_bus) eb.start() else eb.stop();
                operation catch |err| {
                    result.* = err;
                };
            }
        };

        // Ownership rejection must apply both to starting an idle bus and to stopping
        // a running one. Joining transfers the worker's non-atomic result back to us.
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
}
