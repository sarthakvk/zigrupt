const std = @import("std");
const library = @import("library");
const Atomic = std.atomic.Value;
const allocator = std.heap.page_allocator;
extern fn bench_now() u64;
extern fn bench_cpu() u64;
extern fn bench_rss() u64;
extern fn bench_pin(c_int) void;
extern fn bench_sleep() void;
extern "c" fn printf([*:0]const u8, ...) c_int;

const Args = struct {
    capacity: usize,
    producer_count: usize,
    warm: usize,
    count: usize,
    rate: u64,
    check: bool,
    cpus: [6]c_int,
};

// Only ring allocations use this allocator; measurement storage is reported separately.
const RingAllocator = struct {
    var calls: Atomic(usize) = .init(0);
    var bytes: usize = 0;
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const result = allocator.rawAlloc(len, alignment, ret) orelse return null;
        _ = calls.fetchAdd(1, .monotonic);
        bytes += len;
        return result;
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret: usize) void {
        allocator.rawFree(buf, alignment, ret);
    }
    const value: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    } };
};

fn Harness(comptime words: usize, comptime producers: usize, comptime consumers: usize) type {
    return struct {
        const Self = @This();
        const Event = [words]u64;
        const BusySpin = struct {
            pub fn wait() void {}
        };
        const handlers = [_]*const fn ([]const Event) usize{ handle0, handle1, handle2 };
        const Bus = library.EventBus(Event, producers > 1, handlers[0..consumers], BusySpin, BusySpin);
        const Consumer = struct {
            count: usize align(128) = 0,
            sum: u64 = 0,
            hash: u64 = 0,
            max_observed_batch: usize = 0,
            next: [producers]u64 = undefined,
            histogram: []u64,
            trace: []u64,
            end: u64 = 0,
            cpu_end: u64 = 0,
            done: Atomic(usize) = .init(0),
        };
        var args: Args = undefined;
        var bus: Bus = undefined;
        var states: [consumers]Consumer align(128) = undefined;
        var phase: Atomic(usize) = .init(0);
        var ready: Atomic(usize) = .init(0);
        var producer_done: Atomic(usize) = .init(0);
        var slow_entered: Atomic(bool) = .init(false);
        var slow_release: Atomic(bool) = .init(false);
        var published: Atomic(usize) = .init(0);
        var attempted: Atomic(usize) = .init(0);
        var start: u64 = 0;
        var event_base: u64 = 0;
        var cpu_start: u64 = 0;

        fn handle0(events: []const Event) usize {
            return handleBatch(0, events);
        }
        fn handle1(events: []const Event) usize {
            return handleBatch(1, events);
        }
        fn handle2(events: []const Event) usize {
            return handleBatch(2, events);
        }

        fn handleBatch(comptime cid: usize, events: []const Event) usize {
            if (cid >= consumers) unreachable;
            // Observe batching only in correctness runs; measured work stays per-event.
            if (args.check) states[cid].max_observed_batch = @max(states[cid].max_observed_batch, events.len);
            for (events) |event| handle(cid, event);
            return events.len;
        }

        fn handle(comptime cid: usize, event: Event) void {
            if (cid >= consumers) unreachable;
            const s = &states[cid];
            if (s.count == 0) bench_pin(args.cpus[producers + cid]);
            if (args.check and cid == consumers - 1 and s.count == args.warm) {
                slow_entered.store(true, .release);
                while (!slow_release.load(.acquire)) std.atomic.spinLoopHint();
            }
            const id = event[0];
            const pid = id % args.producer_count;
            if (id != s.next[pid]) @panic("loss, duplicate, or producer reordering");
            s.next[pid] += args.producer_count;
            for (event) |word| s.sum +%= word;
            s.hash = s.hash *% 31 +% id;
            if (args.check) s.trace[s.count] = id;
            if (args.rate != 0) {
                const scheduled = start + (id - event_base) * 1_000_000_000 / args.rate;
                const latency = bench_now() - scheduled;
                const shift: u6 = @intCast(64 - @clz(latency | 1) -| 10);
                const bucket = @as(usize, shift) * 1024 + (latency >> shift);
                s.histogram[bucket] += 1;
            }
            s.count += 1;
            if (s.count == args.warm) @memset(s.histogram, 0);
            if (s.count == args.warm or s.count == args.warm + args.count) {
                s.end = bench_now();
                s.cpu_end = bench_cpu();
                s.done.store(s.count, .release);
            }
        }

        fn publish(pid: usize) void {
            bench_pin(args.cpus[pid]);
            _ = ready.fetchAdd(1, .release);
            for (1..3) |round| {
                while (phase.load(.acquire) < round) std.atomic.spinLoopHint();
                const first = if (round == 1) 0 else args.warm;
                const n = if (round == 1) args.warm else args.count;
                var id: u64 = first + pid;
                while (id < first + n) : (id += producers) {
                    if (args.rate != 0) {
                        const scheduled = start + (id - first) * 1_000_000_000 / args.rate;
                        while (bench_now() < scheduled) std.atomic.spinLoopHint();
                    }
                    var event: Event = undefined;
                    inline for (0..words) |j| event[j] = id + j;
                    if (args.check and round == 2) _ = attempted.fetchAdd(1, .monotonic);
                    bus.produce(event) catch @panic("publish failed");
                    if (args.check and round == 2) _ = published.fetchAdd(1, .release);
                }
                _ = producer_done.fetchAdd(1, .release);
            }
            // Keep teardown out of process CPU and completion measurements.
            while (phase.load(.acquire) != 3) bench_sleep();
        }

        fn waitDone(target: usize, produced: usize) void {
            while (producer_done.load(.acquire) < produced) bench_sleep();
            for (&states) |*s| while (s.done.load(.acquire) < target) {
                bench_sleep();
            };
        }

        fn percentile(hist: []u64, n: usize, per_mille: usize) u64 {
            const rank = (n * per_mille + 999) / 1000;
            var total: u64 = 0;
            for (hist, 0..) |v, bucket| {
                total += v;
                if (total >= rank) {
                    const shift: u6 = @intCast(bucket / 1024);
                    return ((@as(u64, bucket % 1024) + 1) << shift) - 1;
                }
            }
            @panic("missing latency samples");
        }

        fn run(a: Args) !void {
            args = a;
            for (&states) |*s| {
                s.* = .{
                    .histogram = try allocator.alloc(u64, if (args.rate > 0) 65536 else 0),
                    .trace = try allocator.alloc(u64, if (args.check) args.warm + args.count else 0),
                };
                @memset(s.histogram, 0);
                for (&s.next, 0..) |*next, pid| next.* = pid;
            }
            defer for (&states) |*s| {
                allocator.free(s.histogram);
                allocator.free(s.trace);
            };
            // Java and Rust acknowledge available batches natively. Do not cap
            // Zigrupt at one event or wait for a full batch before consuming.
            bus = try Bus.init(RingAllocator.value, args.capacity, args.capacity);
            defer bus.deinit();
            try bus.start();
            var threads: [producers]std.Thread = undefined;
            for (&threads, 0..) |*thread, pid| thread.* = try std.Thread.spawn(.{}, publish, .{pid});
            while (ready.load(.acquire) < producers) bench_sleep();
            start = bench_now();
            phase.store(1, .release);
            waitDone(args.warm, producers);
            const warm_elapsed = bench_now() - start;
            const alloc_start = RingAllocator.calls.load(.monotonic);
            cpu_start = bench_cpu();
            event_base = args.warm;
            start = bench_now();
            phase.store(2, .release);
            var blocked: usize = 0;
            if (args.check) {
                while (!slow_entered.load(.acquire)) bench_sleep();
                for (0..50) |_| bench_sleep();
                blocked = published.load(.acquire);
                for (0..20) |_| bench_sleep();
                if (blocked == 0 or blocked > args.capacity + 1 or blocked >= args.count or
                    published.load(.acquire) != blocked or attempted.load(.monotonic) <= blocked)
                    @panic("backpressure was not demonstrated");
                slow_release.store(true, .release);
            }
            waitDone(args.warm + args.count, 2 * producers);
            const allocs = RingAllocator.calls.load(.monotonic) - alloc_start;
            var end: u64 = 0;
            var cpu_end: u64 = 0;
            for (&states) |*s| {
                end = @max(end, s.end);
                cpu_end = @max(cpu_end, s.cpu_end);
            }
            const rss = bench_rss();
            phase.store(3, .release);
            for (threads) |thread| thread.join();
            try bus.stop();
            const total: u64 = args.warm + args.count;
            const expected = words *% (total *% (total - 1) / 2) +% total *% (words * (words - 1) / 2);
            for (&states) |*s| {
                if (s.count != total or s.sum != expected or s.hash != states[0].hash) @panic("invalid delivery");
                if (args.check and !std.mem.eql(u64, s.trace, states[0].trace)) @panic("broadcast order mismatch");
            }
            _ = printf("{\"warm_elapsed_ns\":%llu,\"max_batch_size\":%zu,", warm_elapsed, args.capacity);
            _ = printf("\"valid\":true,\"elapsed_ns\":%llu,\"cpu_ns\":%llu,\"peak_rss_bytes\":%llu,\"ring_requested_bytes\":%zu,\"measurement_bytes\":%zu,\"steady_allocations\":%zu,\"blocked_publications\":%zu,\"consumers\":[", end - start, cpu_end - cpu_start, rss, RingAllocator.bytes, consumers * (if (args.rate > 0) @as(usize, 65536 * 8) else 0), allocs, blocked);
            for (&states, 0..) |*s, cid| {
                if (cid != 0) _ = printf(",");
                _ = printf("{\"count\":%zu,\"checksum\":%llu,\"order_hash\":%llu", s.count, s.sum, s.hash);
                if (args.check) _ = printf(",\"max_observed_batch\":%zu", s.max_observed_batch);
                if (args.rate > 0) _ = printf(",\"samples\":%zu,\"p50_ns\":%llu,\"p99_ns\":%llu,\"p999_ns\":%llu", args.count, percentile(s.histogram, args.count, 500), percentile(s.histogram, args.count, 990), percentile(s.histogram, args.count, 999));
                _ = printf("}");
            }
            _ = printf("]}\n");
        }
    };
}

fn dispatch(comptime words: usize, p: usize, c: usize, args: Args) !void {
    if (p == 1 and c == 1) return Harness(words, 1, 1).run(args);
    if (p == 4 and c == 1) return Harness(words, 4, 1).run(args);
    if (p == 1 and c == 3) return Harness(words, 1, 3).run(args);
    if (p == 3 and c == 3) return Harness(words, 3, 3).run(args);
    return error.UnsupportedTopology;
}

pub export fn bench_main(argc: c_int, argv: [*][*:0]const u8) c_int {
    if (argc < 11) return 2;
    var nums: [8]u64 = undefined;
    for (&nums, 0..) |*n, i| n.* = std.fmt.parseInt(u64, std.mem.span(argv[i + 1]), 10) catch return 2;
    const p = nums[0];
    const c = nums[1];
    if (p + c > 6 or argc != 9 + p + c) return 2;
    var args: Args = .{ .capacity = nums[2], .producer_count = p, .warm = nums[4], .count = nums[5], .rate = nums[6], .check = nums[7] != 0, .cpus = undefined };
    for (0..p + c) |i| args.cpus[i] = std.fmt.parseInt(c_int, std.mem.span(argv[9 + i]), 10) catch return 2;
    if (nums[3] == 8) dispatch(1, p, c, args) catch return 1 else if (nums[3] == 64) dispatch(8, p, c, args) catch return 1 else return 2;
    return 0;
}
