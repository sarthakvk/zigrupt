const std = @import("std");
const builtin = @import("builtin");
const zigrupt = @import("zigrupt");

const buffer_size = 1024;
const max_consumers = 16;

/// Event counts are a lower bound: unreported pilot runs increase them until the
/// requested duration is reached. CPU lists map worker indices to logical CPUs.
const CliArgs = struct {
    publishers: usize = 1,
    consumers: usize = 1,
    events_per_publisher: usize = 100_000,
    repetitions: usize = 5,
    min_duration_ms: u64 = 500,
    publisher_cpus: []const usize = &.{},
    consumer_cpus: []const usize = &.{},

    fn parse(init: std.process.Init) !CliArgs {
        var args = try init.minimal.args.iterateAllocator(init.gpa);
        defer args.deinit();
        _ = args.next();
        var result: CliArgs = .{};
        while (args.next()) |arg| try result.option(init.arena.allocator(), arg);
        try result.validate();
        return result;
    }

    fn option(self: *CliArgs, allocator: std.mem.Allocator, arg: []const u8) !void {
        if (std.mem.cutPrefix(u8, arg, "--publishers=")) |value| {
            self.publishers = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.cutPrefix(u8, arg, "--consumers=")) |value| {
            self.consumers = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.cutPrefix(u8, arg, "--events_per_publisher=")) |value| {
            self.events_per_publisher = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.cutPrefix(u8, arg, "--repetitions=")) |value| {
            self.repetitions = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.cutPrefix(u8, arg, "--min_duration_ms=")) |value| {
            self.min_duration_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.cutPrefix(u8, arg, "--publisher_cpus=")) |value| {
            self.publisher_cpus = try parseCpus(allocator, value);
        } else if (std.mem.cutPrefix(u8, arg, "--consumer_cpus=")) |value| {
            self.consumer_cpus = try parseCpus(allocator, value);
        } else return error.UnknownArgument;
    }

    fn validate(self: CliArgs) !void {
        if (self.publishers == 0 or self.consumers == 0 or
            self.consumers > max_consumers or self.events_per_publisher == 0 or
            self.repetitions < 2 or self.min_duration_ms == 0)
            return error.InvalidArguments;
        if ((self.publisher_cpus.len != 0 and self.publisher_cpus.len != self.publishers) or
            (self.consumer_cpus.len != 0 and self.consumer_cpus.len != self.consumers))
            return error.InvalidCpuCount;
        _ = try std.math.mul(usize, self.publishers, self.events_per_publisher);
        _ = try std.math.add(usize, self.publishers, self.consumers);
    }
};

/// Parse explicit logical CPU IDs; topology and SMT placement remain the caller's choice.
fn parseCpus(allocator: std.mem.Allocator, text: []const u8) ![]const usize {
    const cpus = try allocator.alloc(usize, std.mem.count(u8, text, ",") + 1);
    errdefer allocator.free(cpus);
    var parts = std.mem.splitScalar(u8, text, ',');
    for (cpus) |*cpu| cpu.* = try std.fmt.parseInt(usize, parts.next().?, 10);
    return cpus;
}

/// Validate against the inherited Linux affinity mask, not the machine-wide CPU count.
/// Unpinned workers retain that mask; no automatic placement is imposed.
fn reportPlacement(args: CliArgs) !void {
    var available: usize = undefined;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var allowed: linux.cpu_set_t = undefined;
        if (linux.errno(linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &allowed)) != .SUCCESS)
            return error.AffinityUnavailable;
        available = linux.CPU_COUNT(allowed);
        for ([_][]const usize{ args.publisher_cpus, args.consumer_cpus }) |cpus| {
            for (cpus) |cpu| {
                const bits = @bitSizeOf(usize);
                if (cpu >= @bitSizeOf(linux.cpu_set_t) or
                    allowed[cpu / bits] & (@as(usize, 1) << @intCast(cpu % bits)) == 0)
                    return error.CpuNotAllowed;
            }
        }
    } else {
        if (args.publisher_cpus.len != 0 or args.consumer_cpus.len != 0)
            return error.AffinityUnsupported;
        available = try std.Thread.getCpuCount();
    }
    std.debug.print("Placement ({d} available logical CPUs):\n", .{available});
    for (0..args.publishers) |id| {
        if (args.publisher_cpus.len == 0)
            std.debug.print("  producer {d}: unpinned\n", .{id})
        else
            std.debug.print("  producer {d}: CPU {d}\n", .{ id, args.publisher_cpus[id] });
    }
    for (0..args.consumers) |id| {
        if (args.consumer_cpus.len == 0)
            std.debug.print("  consumer {d}: unpinned\n", .{id})
        else
            std.debug.print("  consumer {d}: CPU {d}\n", .{ id, args.consumer_cpus[id] });
    }
    if (args.publisher_cpus.len == 0 or args.consumer_cpus.len == 0)
        std.debug.print("WARNING: unpinned workers; CPU placement and migration are uncontrolled.\n", .{});
    if (args.publishers + args.consumers > available or sharesCpu(args))
        std.debug.print("WARNING: busy-spinning workers outnumber available CPUs or share an assigned CPU.\n", .{});
    std.debug.print("CPU IDs are logical: distinct IDs may still share an SMT core. Coordinator parks during measurement.\n", .{});
}

fn sharesCpu(args: CliArgs) bool {
    for (args.publisher_cpus, 0..) |cpu, i| {
        for (args.publisher_cpus[0..i]) |other| if (cpu == other) return true;
        for (args.consumer_cpus) |other| if (cpu == other) return true;
    }
    for (args.consumer_cpus, 0..) |cpu, i| {
        for (args.consumer_cpus[0..i]) |other| if (cpu == other) return true;
    }
    return false;
}

/// Pin an existing worker by OS thread ID. Errors abort the run rather than
/// silently reporting results under a placement different from the requested one.
fn pinThread(tid: std.Thread.Id, cpu: usize) !void {
    if (builtin.os.tag != .linux) return error.AffinityUnsupported;
    const linux = std.os.linux;
    if (cpu >= @bitSizeOf(linux.cpu_set_t)) return error.CpuNotAllowed;
    var mask: linux.cpu_set_t = @splat(0);
    mask[cpu / @bitSizeOf(usize)] = @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
    try linux.sched_setaffinity(@intCast(tid), &mask);
}

/// Consumer-major, cache-line-aligned storage. Padding prevents two consumers
/// from writing the same cache line even when the event count is not aligned.
const Samples = struct {
    data: []align(std.atomic.cache_line) i96,
    total: usize,
    consumers: usize,
    stride: usize,

    fn init(allocator: std.mem.Allocator, total: usize, consumers: usize) !Samples {
        const per_line: usize = @max(1, std.atomic.cache_line / @sizeOf(i96));
        const stride = (try std.math.add(usize, total, per_line - 1)) & ~(per_line - 1);
        const length = try std.math.mul(usize, stride, consumers);
        return .{
            .data = try allocator.alignedAlloc(i96, .fromByteUnits(std.atomic.cache_line), length),
            .total = total,
            .consumers = consumers,
            .stride = stride,
        };
    }

    fn deinit(self: Samples, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    /// Compact away padding only after workers stop. Sorting includes every
    /// delivery, but never the unfilled padding at consumer-region boundaries.
    fn percentiles(self: Samples) !struct { p50: i96, p99: i96 } {
        for (0..self.consumers) |id| {
            const region = self.data[id * self.stride ..][0..self.total];
            for (region) |sample| if (sample < 0) return error.InvalidLatencySample;
            std.mem.copyForwards(i96, self.data[id * self.total ..][0..self.total], region);
        }
        const values = self.data[0 .. self.total * self.consumers];
        std.mem.sort(i96, values, {}, std.sort.asc(i96));
        // Nearest-rank percentiles without multiplying the sample count.
        return .{ .p50 = values[values.len - values.len / 2 - 1], .p99 = values[values.len - values.len / 100 - 1] };
    }
};

/// Separate compile-time modes keep clock reads and sample writes out of the
/// throughput handler. Both measure broadcast delivery, including backpressure.
fn Benchmark(comptime consumer_count: usize, comptime multi_producer: bool, comptime measure_latency: bool) type {
    return struct {
        const Self = @This();
        const Event = struct {
            benchmark: *Self,
            index: usize,
            sent: std.Io.Timestamp = undefined,
        };
        const Counter = struct {
            remaining: usize align(std.atomic.cache_line) = 0,
            tid: std.Thread.Id = undefined,
        };
        const handlers = blk: {
            var result: [consumer_count]*const fn (Event) void = undefined;
            for (&result, 0..) |*handler, id| handler.* = struct {
                fn handle(event: Event) void {
                    const self = event.benchmark;
                    if (measure_latency) {
                        const elapsed = event.sent.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds();
                        const samples = self.samples.?;
                        samples.data[id * samples.stride + event.index] = elapsed;
                    }
                    // Only this consumer touches its countdown during a phase.
                    // Shared synchronization occurs once, on its final delivery.
                    self.consumed[id].remaining -= 1;
                    if (self.consumed[id].remaining == 0) {
                        self.consumed[id].tid = std.Thread.getCurrentId();
                        // The acquire/release chain gathers every consumer's writes
                        // before the last one publishes completion to the coordinator.
                        if (self.done.fetchAdd(1, .acq_rel) + 1 == consumer_count) {
                            self.end = std.Io.Clock.awake.now(self.io);
                            self.completed.set(self.io);
                        }
                    }
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
        consumed: [consumer_count]Counter = @splat(.{}),
        ready: std.atomic.Value(usize) = .init(0),
        ready_event: std.Io.Event = .unset,
        go: std.atomic.Value(bool) = .init(false),
        abort: std.atomic.Value(bool) = .init(false),
        affinity_failed: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(usize) = .init(0),
        completed: std.Io.Event = .unset,
        end: std.Io.Timestamp = undefined,
        samples: ?Samples = null,
        publisher_cpus: []const usize = &.{},

        fn publish(self: *Self, bus: *Bus, id: usize, publishers: usize, count: usize) void {
            if (self.publisher_cpus.len != 0) {
                pinThread(std.Thread.getCurrentId(), self.publisher_cpus[id]) catch {
                    self.affinity_failed.store(true, .release);
                };
            }
            if (self.ready.fetchAdd(1, .acq_rel) + 1 == publishers) self.ready_event.set(self.io);
            while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
            if (self.abort.load(.acquire)) return;
            for (0..count) |index| {
                var event: Event = .{ .benchmark = self, .index = id * count + index };
                if (measure_latency) event.sent = std.Io.Clock.awake.now(self.io);
                bus.produce(event) catch unreachable;
            }
        }

        /// Time release of ready producers through the last handler's completion.
        /// The coordinator sleeps; its wakeup and thread joins are outside timing.
        fn phase(self: *Self, bus: *Bus, threads: []std.Thread, count: usize) !i96 {
            const total = try std.math.mul(usize, threads.len, count);
            for (&self.consumed) |*counter| counter.remaining = total;
            self.ready.store(0, .monotonic);
            self.ready_event.reset();
            self.go.store(false, .monotonic);
            self.abort.store(false, .monotonic);
            self.affinity_failed.store(false, .monotonic);
            self.done.store(0, .monotonic);
            self.completed.reset();

            var started: usize = 0;
            defer {
                // Release partially started producers too. On failure they see
                // abort before go, so no incomplete phase reaches the consumers.
                self.go.store(true, .release);
                for (threads[0..started]) |thread| thread.join();
            }
            errdefer self.abort.store(true, .release);
            for (threads, 0..) |*thread, id| {
                thread.* = try std.Thread.spawn(.{}, publish, .{ self, bus, id, threads.len, count });
                started += 1;
            }
            self.ready_event.waitUncancelable(self.io);
            if (self.affinity_failed.load(.acquire)) return error.AffinityFailed;
            const start = std.Io.Clock.awake.now(self.io);
            self.go.store(true, .release);
            self.completed.waitUncancelable(self.io);
            return start.durationTo(self.end).toNanoseconds();
        }

        /// Each run owns fresh workers and a fresh bus. A discovery delivery lets
        /// us pin consumers by their actual handler IDs without changing the bus API.
        fn run(self: *Self, allocator: std.mem.Allocator, args: CliArgs, count: usize) !i96 {
            self.publisher_cpus = args.publisher_cpus;
            const threads = try allocator.alloc(std.Thread, args.publishers);
            defer allocator.free(threads);
            var bus = try Bus.init(allocator, buffer_size);
            defer bus.deinit();
            try bus.start();
            defer bus.stop() catch unreachable;

            if (args.consumer_cpus.len != 0) {
                _ = try self.phase(&bus, threads, 1);
                for (self.consumed, args.consumer_cpus) |counter, cpu| try pinThread(counter.tid, cpu);
            }
            _ = try self.phase(&bus, threads, @min(100_000, count));
            // Prefault storage and reset discovery/warmup samples before timing.
            if (measure_latency) @memset(self.samples.?.data, -1);
            const elapsed = try self.phase(&bus, threads, count);
            if (elapsed <= 0) return error.InvalidDuration;
            return elapsed;
        }
    };
}

/// Median and observed range across independent runs; the range is not a
/// confidence interval, and no best-run result is used as the headline.
fn summarize(values: []f64) struct { median: f64, min: f64, max: f64 } {
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const middle = values.len / 2;
    const median = if (values.len % 2 == 0) (values[middle - 1] + values[middle]) / 2 else values[middle];
    return .{ .median = median, .min = values[0], .max = values[values.len - 1] };
}

/// Calibrate each mode independently to avoid sizing latency storage from the
/// faster uninstrumented throughput rate. Pilot results are never reported as runs.
fn runMode(init: std.process.Init, args: CliArgs, comptime consumers: usize, comptime multi_producer: bool, comptime latency: bool) !void {
    const Bench = Benchmark(consumers, multi_producer, latency);
    const target_ns = @as(i96, args.min_duration_ms) * std.time.ns_per_ms;
    var count = args.events_per_publisher;
    while (true) {
        const total = try std.math.mul(usize, args.publishers, count);
        const samples: ?Samples = if (latency) try Samples.init(init.gpa, total, consumers) else null;
        defer if (samples) |storage| storage.deinit(init.gpa);
        var pilot: Bench = .{ .io = init.io, .samples = samples };
        if (try pilot.run(init.gpa, args, count) >= target_ns) break;
        count = try std.math.mul(usize, count, 2);
    }
    const total = try std.math.mul(usize, args.publishers, count);
    const samples: ?Samples = if (latency) try Samples.init(init.gpa, total, consumers) else null;
    defer if (samples) |storage| storage.deinit(init.gpa);
    const rates = try init.gpa.alloc(f64, args.repetitions);
    defer init.gpa.free(rates);
    const p50s = try init.gpa.alloc(f64, args.repetitions);
    defer init.gpa.free(p50s);
    const p99s = try init.gpa.alloc(f64, args.repetitions);
    defer init.gpa.free(p99s);
    std.debug.print("{s}: {d} events/producer/run, {d} repetitions", .{ if (latency) "Latency" else "Throughput", count, args.repetitions });
    if (samples) |storage| std.debug.print(", {d} sample-storage bytes", .{storage.data.len * @sizeOf(i96)});
    std.debug.print("\n", .{});
    for (0..args.repetitions) |rep| {
        var bench: Bench = .{ .io = init.io, .samples = samples };
        const elapsed_ns = try bench.run(init.gpa, args, count);
        const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
        rates[rep] = @as(f64, @floatFromInt(total)) / seconds / 1e6;
        if (latency) {
            const percentiles = try samples.?.percentiles();
            p50s[rep] = @floatFromInt(percentiles.p50);
            p99s[rep] = @floatFromInt(percentiles.p99);
            std.debug.print("  run {d}: p50 {d} ns, p99 {d} ns ({d:.3} ms)\n", .{ rep + 1, percentiles.p50, percentiles.p99, seconds * 1000 });
        } else {
            std.debug.print("  run {d}: {d:.3} million events/s ({d:.3} ms)\n", .{ rep + 1, rates[rep], seconds * 1000 });
        }
        // Calibration predicts duration, but frequency/scheduler changes can
        // shorten later runs. Disclose that instead of silently filtering them.
        if (elapsed_ns < target_ns) std.debug.print("  WARNING: run shorter than calibration target ({d} ms).\n", .{args.min_duration_ms});
    }
    if (latency) {
        const p50 = summarize(p50s);
        const p99 = summarize(p99s);
        std.debug.print("Latency p50: median {d:.1} ns, range [{d:.1}, {d:.1}] ns\n", .{ p50.median, p50.min, p50.max });
        std.debug.print("Latency p99: median {d:.1} ns, range [{d:.1}, {d:.1}] ns\n", .{ p99.median, p99.min, p99.max });
    } else {
        const rate = summarize(rates);
        std.debug.print("Throughput: median {d:.3}, range [{d:.3}, {d:.3}] million events/s\n", .{ rate.median, rate.min, rate.max });
    }
}

pub fn main(init: std.process.Init) !void {
    const args = CliArgs.parse(init) catch |err| {
        std.debug.print("Usage: zig build bench -- --publishers=1 --consumers=1 --events_per_publisher=100000 --repetitions=5 --min_duration_ms=500 [--publisher_cpus=0] [--consumer_cpus=1]\nConsumers: 1..{d}; repetitions >= 2; counts/duration > 0; one CPU ID per worker.\n", .{max_consumers});
        return err;
    };
    try reportPlacement(args);
    std.debug.print("Ring buffer: {d} producers, {d} consumers, busy spin, capacity {d}, ReleaseFast\n", .{
        args.publishers, args.consumers, buffer_size,
    });
    std.debug.print("Throughput is end-to-end broadcast delivery (unique events/s), including countdown bookkeeping.\nLatency is a separate saturated, instrumented run: before produce() to the handler clock read, including backpressure and queueing. Clock/sample overhead remains; this is not fixed-arrival-rate latency.\n", .{});
    // The bus requires its handlers at comptime; instantiate a bounded set of consumer counts.
    switch (args.consumers) {
        inline 1...max_consumers => |consumers| {
            if (args.publishers == 1) {
                try runMode(init, args, consumers, false, false);
                try runMode(init, args, consumers, false, true);
            } else {
                try runMode(init, args, consumers, true, false);
                try runMode(init, args, consumers, true, true);
            }
        },
        else => unreachable,
    }
}

test "options reject invalid counts and CPU-list lengths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var args: CliArgs = .{};
    try args.option(arena.allocator(), "--publisher_cpus=2,4");
    try std.testing.expectError(error.InvalidCpuCount, args.validate());
    try args.option(arena.allocator(), "--publishers=2");
    try args.validate();
    try args.option(arena.allocator(), "--repetitions=1");
    try std.testing.expectError(error.InvalidArguments, args.validate());
    try std.testing.expectError(error.InvalidCharacter, args.option(arena.allocator(), "--consumer_cpus=1,"));
    try std.testing.expectError(error.UnknownArgument, args.option(arena.allocator(), "--unknown=1"));
}

test "zero counts, unsupported consumer counts, and event-count overflow are rejected" {
    try std.testing.expectError(error.InvalidArguments, (CliArgs{ .publishers = 0 }).validate());
    try std.testing.expectError(error.InvalidArguments, (CliArgs{ .consumers = 0 }).validate());
    try std.testing.expectError(error.InvalidArguments, (CliArgs{ .consumers = max_consumers + 1 }).validate());
    try std.testing.expectError(error.InvalidArguments, (CliArgs{ .events_per_publisher = 0 }).validate());
    try std.testing.expectError(error.InvalidArguments, (CliArgs{ .min_duration_ms = 0 }).validate());
    try std.testing.expectError(error.Overflow, (CliArgs{ .publishers = 2, .events_per_publisher = std.math.maxInt(usize) }).validate());
}

test "shared logical CPUs are detected within and across roles" {
    try std.testing.expect(sharesCpu(.{ .publisher_cpus = &.{ 2, 2 } }));
    try std.testing.expect(sharesCpu(.{ .consumer_cpus = &.{ 3, 3 } }));
    try std.testing.expect(sharesCpu(.{ .publisher_cpus = &.{2}, .consumer_cpus = &.{2} }));
    try std.testing.expect(!sharesCpu(.{ .publisher_cpus = &.{ 2, 4 }, .consumer_cpus = &.{ 6, 8 } }));
}

test "sample regions are aligned and percentiles exclude padding" {
    const samples = try Samples.init(std.testing.allocator, 3, 2);
    defer samples.deinit(std.testing.allocator);
    @memset(samples.data, -1);
    for (0..2) |id| {
        const region = samples.data[id * samples.stride ..][0..3];
        try std.testing.expectEqual(0, @intFromPtr(region.ptr) % std.atomic.cache_line);
        for (region, 0..) |*sample, index| sample.* = @intCast(id * 3 + index + 1);
    }
    const result = try samples.percentiles();
    try std.testing.expectEqual(3, result.p50);
    try std.testing.expectEqual(6, result.p99);
    @memset(samples.data, -1);
    try std.testing.expectError(error.InvalidLatencySample, samples.percentiles());
    try std.testing.expectError(error.Overflow, Samples.init(std.testing.allocator, std.math.maxInt(usize), 2));
}

test "summary reports odd and even medians and the observed range" {
    var odd = [_]f64{ 9, 1, 3 };
    const result = summarize(&odd);
    try std.testing.expectEqual(3, result.median);
    try std.testing.expectEqual(1, result.min);
    try std.testing.expectEqual(9, result.max);
    var even = [_]f64{ 8, 2, 4, 6 };
    try std.testing.expectEqual(5, summarize(&even).median);
}

test "producer affinity failure releases waiting producers without publishing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var bench: Benchmark(2, true, false) = .{ .io = std.testing.io };
    const args: CliArgs = .{ .publishers = 2, .consumers = 2, .publisher_cpus = &.{ std.math.maxInt(usize), std.math.maxInt(usize) } };
    // Invalid IDs fail inside both workers, after spawning, exercising the
    // abort/start-gate ordering rather than just rejecting CLI configuration.
    try std.testing.expectError(error.AffinityFailed, bench.run(std.testing.allocator, args, 10));
    try std.testing.expectEqual(0, bench.done.load(.acquire));
    for (bench.consumed) |counter| try std.testing.expectEqual(20, counter.remaining);
}

test "repeated phases complete every consumer and publish worker-side end time" {
    inline for (.{ false, true }) |multi| {
        inline for (.{ false, true }) |latency| {
            const publishers: usize = if (multi) 3 else 1;
            const count: usize = 2049;
            const samples = try Samples.init(std.testing.allocator, publishers * count, 3);
            defer samples.deinit(std.testing.allocator);
            var bench: Benchmark(3, multi, latency) = .{ .io = std.testing.io, .samples = if (latency) samples else null };
            const args: CliArgs = .{ .publishers = publishers, .consumers = 3 };
            for (0..2) |_| {
                const elapsed = try bench.run(std.testing.allocator, args, count);
                try std.testing.expect(elapsed > 0);
                try std.testing.expect(bench.completed.isSet());
                try std.testing.expectEqual(3, bench.done.load(.acquire));
                for (bench.consumed) |counter| try std.testing.expectEqual(0, counter.remaining);
                if (latency) _ = try samples.percentiles();
            }
        }
    }
}
