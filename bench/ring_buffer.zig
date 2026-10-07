const std = @import("std");
const zigrupt = @import("zigrupt");

const buffer_size = 1024;
const max_consumers = 16;

const CliArgs = struct {
    publishers: usize = 1,
    consumers: usize = 1,
    events_per_publisher: usize = 100_000,

    fn parse(init: std.process.Init) !CliArgs {
        var args = try init.minimal.args.iterateAllocator(init.gpa);
        defer args.deinit();
        _ = args.next();
        var result: CliArgs = .{};
        while (args.next()) |arg| {
            if (std.mem.cutPrefix(u8, arg, "--publishers=")) |value| {
                result.publishers = try std.fmt.parseInt(usize, value, 10);
            } else if (std.mem.cutPrefix(u8, arg, "--consumers=")) |value| {
                result.consumers = try std.fmt.parseInt(usize, value, 10);
            } else if (std.mem.cutPrefix(u8, arg, "--events_per_publisher=")) |value| {
                result.events_per_publisher = try std.fmt.parseInt(usize, value, 10);
            } else return error.UnknownArgument;
        }
        if (result.publishers == 0 or result.consumers == 0 or
            result.consumers > max_consumers or result.events_per_publisher == 0)
            return error.InvalidArguments;
        _ = try std.math.mul(usize, result.publishers, result.events_per_publisher);
        return result;
    }
};

fn Benchmark(comptime consumer_count: usize, comptime multi_producer: bool, comptime measure_latency: bool) type {
    return struct {
        const Self = @This();
        const Event = struct {
            benchmark: *Self,
            index: usize,
            sent: std.Io.Timestamp = undefined,
        };
        const Counter = struct {
            value: usize align(std.atomic.cache_line) = 0,
        };
        const handlers = blk: {
            var result: [consumer_count]*const fn (Event) void = undefined;
            for (&result, 0..) |*handler, id| handler.* = struct {
                fn handle(event: Event) void {
                    const self = event.benchmark;
                    if (measure_latency) {
                        self.samples[event.index * consumer_count + id] =
                            event.sent.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds();
                    }
                    self.consumed[id].value += 1;
                    // Each consumer owns its counter; acknowledge only its final delivery.
                    if (self.consumed[id].value == self.total)
                        _ = self.done.fetchAdd(1, .release);
                }
            }.handle;
            break :blk result;
        };
        const Bus = zigrupt.EventBus(
            Event,
            multi_producer,
            &handlers,
            zigrupt.waiting_strategy.BusySpin,
            zigrupt.waiting_strategy.BusySpin,
        );

        io: std.Io,
        total: usize = 0,
        consumed: [consumer_count]Counter = @splat(.{}),
        ready: std.atomic.Value(usize) = .init(0),
        go: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(usize) = .init(0),
        samples: []i96 = &.{},

        fn publish(self: *Self, bus: *Bus, id: usize, count: usize) void {
            _ = self.ready.fetchAdd(1, .release);
            while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
            for (0..count) |index| {
                var event: Event = .{ .benchmark = self, .index = id * count + index };
                if (measure_latency) event.sent = std.Io.Clock.awake.now(self.io);
                bus.produce(event) catch unreachable;
            }
        }

        fn phase(self: *Self, bus: *Bus, threads: []std.Thread, count: usize) !i96 {
            self.total = threads.len * count;
            self.consumed = @splat(.{});
            self.ready.store(0, .monotonic);
            self.go.store(false, .monotonic);
            self.done.store(0, .monotonic);

            var started: usize = 0;
            defer {
                // Also release and join partially started producers if spawning fails.
                self.go.store(true, .release);
                for (threads[0..started]) |thread| thread.join();
            }
            for (threads, 0..) |*thread, id| {
                thread.* = try std.Thread.spawn(.{}, publish, .{ self, bus, id, count });
                started += 1;
            }
            while (self.ready.load(.acquire) != threads.len) std.atomic.spinLoopHint();
            const start = std.Io.Clock.awake.now(self.io);
            self.go.store(true, .release);
            while (self.done.load(.acquire) != consumer_count) std.atomic.spinLoopHint();
            // Time all deliveries, excluding thread creation/join and bus shutdown.
            return start.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds();
        }

        fn run(self: *Self, allocator: std.mem.Allocator, args: CliArgs) !i96 {
            const threads = try allocator.alloc(std.Thread, args.publishers);
            defer allocator.free(threads);
            var bus = try Bus.init(allocator, buffer_size);
            defer bus.deinit();
            try bus.start();
            defer bus.stop() catch unreachable;

            _ = try self.phase(&bus, threads, @min(10_000, args.events_per_publisher));
            // Prefault the sample storage outside timing and detect missing deliveries.
            if (measure_latency) @memset(self.samples, -1);
            return self.phase(&bus, threads, args.events_per_publisher);
        }
    };
}

fn run(init: std.process.Init, args: CliArgs, comptime consumers: usize, comptime multi_producer: bool) !void {
    const total = args.publishers * args.events_per_publisher;
    const deliveries = try std.math.mul(usize, total, consumers);
    var throughput: Benchmark(consumers, multi_producer, false) = .{ .io = init.io };
    const elapsed_ns = try throughput.run(init.gpa, args);
    const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    std.debug.print("Throughput: {d:.3} million events/s ({d} published events, {d:.3} ms)\n", .{
        @as(f64, @floatFromInt(total)) / seconds / 1e6,
        total,
        seconds * 1000,
    });

    const samples = try init.gpa.alloc(i96, deliveries);
    defer init.gpa.free(samples);
    var latency: Benchmark(consumers, multi_producer, true) = .{ .io = init.io, .samples = samples };
    _ = try latency.run(init.gpa, args);
    for (samples) |sample| if (sample < 0) return error.InvalidLatencySample;
    std.mem.sort(i96, samples, {}, std.sort.asc(i96));
    // Nearest-rank percentiles, without overflowing on large sample counts.
    const p50 = deliveries - deliveries / 2 - 1;
    const p99 = deliveries - deliveries / 100 - 1;
    std.debug.print("Latency: p50 {d} ns, p99 {d} ns ({d} deliveries)\n", .{
        samples[p50], samples[p99], deliveries,
    });
}

pub fn main(init: std.process.Init) !void {
    const args = CliArgs.parse(init) catch |err| {
        std.debug.print("Usage: zig build bench -- --publishers=1 --consumers=1 --events_per_publisher=100000\nConsumers: 1..{d}; all values must be positive.\n", .{max_consumers});
        return err;
    };
    std.debug.print("Ring buffer: {d} producers, {d} consumers, busy spin, capacity {d}, ReleaseFast\n", .{
        args.publishers, args.consumers, buffer_size,
    });
    std.debug.print("Every consumer receives every event. Latency is a separate instrumented run, measured before produce() to handler entry, including backpressure and queueing.\n", .{});
    // The bus requires its handlers at comptime; instantiate a bounded set of consumer counts.
    switch (args.consumers) {
        inline 1...max_consumers => |consumers| {
            if (args.publishers == 1) {
                try run(init, args, consumers, false);
            } else {
                try run(init, args, consumers, true);
            }
        },
        else => unreachable,
    }
}
