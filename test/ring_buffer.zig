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

test "write safety limit caches the slowest consumer's progress" {
    const handler = struct {
        fn handle(_: usize) void {}
    }.handle;
    const test_handlers = [_]*const fn (usize) void{ handler, handler };

    inline for (.{ false, true }) |multi_producer| {
        for ([_]usize{ 1, 8 }) |capacity| {
            const Bus = RingBufferEventBus(usize, multi_producer, &test_handlers, waiting_strategy.BusySpin, waiting_strategy.BusySpin);
            var bus = try Bus.init(std.testing.allocator, capacity);
            defer bus.deinit();

            try std.testing.expectEqual(capacity, if (multi_producer) bus.sequencer.safe_to_write_through.value.load(.acquire) else bus.sequencer.safe_to_write_through);
            try std.testing.expect(bus.sequencer.isSlotSafeToWrite(capacity, bus.consumer_seq));
            try std.testing.expect(!bus.sequencer.isSlotSafeToWrite(capacity + 1, bus.consumer_seq));

            bus.consumer_seq[0].value.store(5, .release);
            try std.testing.expect(!bus.sequencer.isSlotSafeToWrite(capacity + 1, bus.consumer_seq));

            bus.consumer_seq[1].value.store(3, .release);
            try std.testing.expect(bus.sequencer.isSlotSafeToWrite(capacity + 1, bus.consumer_seq));
            try std.testing.expectEqual(capacity + 2, if (multi_producer) bus.sequencer.safe_to_write_through.value.load(.acquire) else bus.sequencer.safe_to_write_through);

            bus.consumer_seq[1].value.store(7, .release);
            try std.testing.expect(bus.sequencer.isSlotSafeToWrite(capacity + 2, bus.consumer_seq));
            // A cache hit must not refresh the limit even when consumers advanced.
            try std.testing.expectEqual(capacity + 2, if (multi_producer) bus.sequencer.safe_to_write_through.value.load(.acquire) else bus.sequencer.safe_to_write_through);

            try std.testing.expect(bus.sequencer.isSlotSafeToWrite(capacity + 4, bus.consumer_seq));
            try std.testing.expectEqual(capacity + 4, if (multi_producer) bus.sequencer.safe_to_write_through.value.load(.acquire) else bus.sequencer.safe_to_write_through);
            try std.testing.expect(!bus.sequencer.isSlotSafeToWrite(capacity + 5, bus.consumer_seq));
        }
    }
}

test "write safety limit handles no consumers and the sequence upper bound" {
    const handler = struct {
        fn handle(_: usize) void {}
    }.handle;
    const test_handlers = [_]*const fn (usize) void{handler};

    inline for (.{ false, true }) |multi_producer| {
        inline for (.{ test_handlers[0..0], test_handlers[0..] }) |event_handlers| {
            const Bus = RingBufferEventBus(usize, multi_producer, event_handlers, waiting_strategy.BusySpin, waiting_strategy.BusySpin);
            var bus = try Bus.init(std.testing.allocator, 8);
            defer bus.deinit();

            for (bus.consumer_seq) |*consumer| consumer.value.store(std.math.maxInt(usize) - 1, .release);
            try std.testing.expect(bus.sequencer.isSlotSafeToWrite(std.math.maxInt(usize), bus.consumer_seq));
            try std.testing.expectEqual(std.math.maxInt(usize), if (multi_producer) bus.sequencer.safe_to_write_through.value.load(.acquire) else bus.sequencer.safe_to_write_through);
        }
    }
}
