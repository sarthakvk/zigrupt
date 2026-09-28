const std = @import("std");
const Disruptor = @import("zigrupt").Disruptor;

const buffer_size = 1024;
const minimum_items = 16384;
const target_work = 1_048_576;

// Same bounded broadcast contract as Disruptor: each consumer sees every item.
fn LockedQueue(comptime T: type, comptime consumers: usize) type {
    return struct {
        const Self = @This();

        lock: std.atomic.Mutex = .unlocked,
        buffer: [buffer_size]T = undefined,
        published: usize = 0,
        consumed: [consumers]usize = @splat(0),

        fn acquire(self: *Self) void {
            while (!self.lock.tryLock()) std.Thread.yield() catch {};
        }

        pub fn publish(self: *Self, value: T) void {
            while (true) {
                self.acquire();
                var free = true;
                for (self.consumed) |next| {
                    if (self.published - next == buffer_size) {
                        free = false;
                        break;
                    }
                }
                if (free) {
                    self.buffer[self.published % buffer_size] = value;
                    self.published += 1;
                    self.lock.unlock();
                    return;
                }
                self.lock.unlock();
                std.Thread.yield() catch {};
            }
        }

        pub fn consume(self: *Self, id: usize) ?T {
            self.acquire();
            defer self.lock.unlock();
            const next = self.consumed[id];
            if (next == self.published) return null;
            const value = self.buffer[next % buffer_size];
            self.consumed[id] = next + 1;
            return value;
        }
    };
}

// Queue must default-initialize and provide publish(usize) and consume(id) ?usize.
fn Bench(comptime Queue: type, comptime publishers: usize, comptime consumers: usize) type {
    return struct {
        const Self = @This();
        const per_publisher = @max(minimum_items, target_work / (publishers * consumers)) / publishers;
        const total = per_publisher * publishers;

        queue: Queue = .{},
        go: std.atomic.Value(bool) = .init(false),
        ready: std.atomic.Value(usize) = .init(0),
        valid: [consumers]bool = @splat(false),

        fn wait(self: *Self) void {
            _ = self.ready.fetchAdd(1, .release);
            while (!self.go.load(.acquire)) std.Thread.yield() catch {};
        }

        fn publish(self: *Self, id: usize) void {
            self.wait();
            for (0..per_publisher) |index| self.queue.publish(id * per_publisher + index);
        }

        fn consume(self: *Self, id: usize) void {
            self.wait();
            var next: [publishers]usize = @splat(0);
            var correct = true;
            for (0..total) |_| {
                const value = while (true) {
                    if (self.queue.consume(id)) |item| break item;
                    std.Thread.yield() catch {};
                };
                if (value >= total) {
                    correct = false;
                    continue;
                }
                const source = value / per_publisher;
                const index = value % per_publisher;
                if (index != next[source]) correct = false;
                next[source] += 1;
            }
            for (next) |count| {
                if (count != per_publisher) correct = false;
            }
            if (self.queue.consume(id) != null) correct = false;
            self.valid[id] = correct;
        }

        fn run(self: *Self, io: std.Io, name: []const u8) !void {
            var threads: [publishers + consumers]std.Thread = undefined;
            for (0..consumers) |id| threads[id] = try std.Thread.spawn(.{}, consume, .{ self, id });
            for (0..publishers) |id| threads[consumers + id] = try std.Thread.spawn(.{}, publish, .{ self, id });

            while (self.ready.load(.acquire) != threads.len) std.Thread.yield() catch {};
            const start = std.Io.Clock.awake.now(io);
            self.go.store(true, .release);
            for (threads) |thread| thread.join();
            const elapsed_ns = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();

            for (self.valid) |valid| {
                if (!valid) {
                    std.debug.print("{s:<17} {d:>3} {d:>3} {d:>8}          -          -  FAIL\n", .{
                        name, publishers, consumers, total,
                    });
                    return error.IncorrectResult;
                }
            }
            const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
            const rate = @as(f64, @floatFromInt(total)) / seconds / 1e6;
            std.debug.print("{s:<17} {d:>3} {d:>3} {d:>8} {d:>10.3} {d:>10.3}  OK\n", .{
                name, publishers, consumers, total, seconds * 1000, rate,
            });
        }
    };
}

fn case(comptime publishers: usize, comptime consumers: usize, io: std.Io) !void {
    const DisruptorQueue = Disruptor(usize, .{
        .buffer_size = buffer_size,
        .publisher_count = publishers,
        .consumer_count = consumers,
    });
    var disruptor: Bench(DisruptorQueue, publishers, consumers) = .{};
    try disruptor.run(io, "Disruptor");

    var locked: Bench(LockedQueue(usize, consumers), publishers, consumers) = .{};
    try locked.run(io, "Locked ring");
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("M/s = million published items/s; every subscriber receives all items (order checked)\n", .{});
    std.debug.print("Queue             Pub Sub    Items         ms        M/s  Check\n", .{});
    std.debug.print("----------------------------------------------------------------\n", .{});
    inline for (.{ .{ 1, 1 }, .{ 1, 2 }, .{ 2, 1 }, .{ 2, 2 }, .{ 4, 4 }, .{ 8, 8 }, .{ 16, 16 }, .{ 32, 32 }, .{ 64, 64 } }) |counts| {
        try case(counts[0], counts[1], io);
    }
}
