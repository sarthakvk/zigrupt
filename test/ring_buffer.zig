const std = @import("std");
const RingBufferEventBus = @import("zigrupt").EventBus;
const waiting_strategy = @import("zigrupt").waiting_strategy;
const Recorder = @import("support/utils.zig").Recorder;

const handlers = [_]*const fn (usize) void{Recorder(0, 1).handle};

test "Ring buffer init" {
    inline for (.{ false, true }) |multi_producer| {
        const Bus = RingBufferEventBus(
            usize,
            multi_producer,
            &handlers,
            waiting_strategy.BusySpin,
            waiting_strategy.BusySpin,
        );
        var bus = try Bus.init(std.testing.allocator, 1024);
        defer bus.deinit();

        try std.testing.expectError(error.IncorrectBufferSize, Bus.init(std.testing.allocator, 120));
    }
}

test "DuplicateStart" {
    inline for (.{ false, true }) |multi_producer| {
        const Bus = RingBufferEventBus(
            usize,
            multi_producer,
            &handlers,
            waiting_strategy.BusySpin,
            waiting_strategy.BusySpin,
        );
        var bus = try Bus.init(std.testing.allocator, 1024);
        defer bus.deinit();

        try bus.start();
        defer bus.stop() catch {};

        try std.testing.expectError(error.BusRunning, bus.start());
    }
}

test "start and stop require lifecycle owner" {
    inline for (.{ false, true }) |multi_producer| {
        const Bus = RingBufferEventBus(
            usize,
            multi_producer,
            &handlers,
            waiting_strategy.BusySpin,
            waiting_strategy.BusySpin,
        );
        var bus = try Bus.init(std.testing.allocator, 1024);
        defer bus.deinit();

        const worker = struct {
            fn run(eb: *Bus, result: *?anyerror, start_bus: bool) void {
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
}
