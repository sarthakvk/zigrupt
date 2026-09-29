const std = @import("std");
const Disruptor = @import("zigrupt").Disruptor;

const CliArgs = struct {
    publishers: usize = 1,
    consumers: usize = 1,
    events_per_publisher: usize = 100_000,

    const Self = @This();
    const fields = @typeInfo(Self).@"struct".fields;

    pub fn init(allocator: std.mem.Allocator, minimal: std.process.Init.Minimal) !CliArgs {
        var args = try minimal.args.iterateAllocator(allocator);
        defer args.deinit();

        // skip executable name
        _ = args.next();
        var out: Self = .{};

        while (args.next()) |arg| {
            if (std.mem.cutPrefix(u8, arg, "--publishers=")) |val| {
                out.publishers = try std.fmt.parseInt(usize, val, 10);
            } else if (std.mem.cutPrefix(u8, arg, "--consumers=")) |val| {
                out.consumers = try std.fmt.parseInt(usize, val, 10);
            } else if (std.mem.cutPrefix(u8, arg, "--events_per_publisher=")) |val| {
                out.events_per_publisher = try std.fmt.parseInt(usize, val, 10);
            } else {
                std.debug.print("Unknown argument {s}\n", .{arg});
            }
        }

        return out;
    }
};

// Same bounded broadcast contract as Disruptor: each consumer sees every item.
fn LockedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        lock: std.atomic.Mutex = .unlocked,
        buffer: std.ArrayList(T) = .empty,
        consumers: []usize,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, consumer_count: usize) !Self {
            const positions = try allocator.alloc(usize, consumer_count);
            @memset(positions, 0);
            return .{ .consumers = positions, .allocator = allocator };
        }

        fn acquire(self: *Self) void {
            while (!self.lock.tryLock()) std.Thread.yield() catch {};
        }

        fn release(self: *Self) void {
            self.lock.unlock();
        }

        pub fn publish(self: *Self, value: T) void {
            self.acquire();
            defer self.release();

            self.buffer.append(self.allocator, value) catch unreachable;

            std.Thread.yield() catch {};
        }

        pub fn consume(self: *Self, id: usize) ?T {
            self.acquire();
            defer self.release();
            if (self.buffer.items.len <= self.consumers[id]) return null;
            defer self.consumers[id] += 1;

            return self.buffer.items[self.consumers[id]];
        }
    };
}

// Queue provides publish(usize) and consume(id) ?usize.
fn Bench(comptime Queue: type) type {
    return struct {
        const Self = @This();

        queue: Queue,
        publishers: usize,
        consumers: usize,
        per_publisher: usize,
        go: std.atomic.Value(bool) = .init(false),
        ready: std.atomic.Value(usize) = .init(0),
        threads: []std.Thread,

        fn init(
            allocator: std.mem.Allocator,
            queue: Queue,
            publishers: usize,
            consumers: usize,
            per_publisher: usize,
        ) !Self {
            const threads = try allocator.alloc(std.Thread, publishers + consumers);
            return .{
                .queue = queue,
                .publishers = publishers,
                .consumers = consumers,
                .per_publisher = per_publisher,
                .threads = threads,
            };
        }

        fn wait(self: *Self) void {
            _ = self.ready.fetchAdd(1, .release);
            while (!self.go.load(.acquire)) std.Thread.yield() catch {};
        }

        fn publish(self: *Self, id: usize) void {
            self.wait();
            for (0..self.per_publisher) |_| self.queue.publish(id);
        }

        fn consume(self: *Self, id: usize) void {
            const total = self.per_publisher * self.publishers;
            var consumed: usize = 0;
            self.wait();
            while (consumed < total) {
                if (self.queue.consume(id) != null) consumed += 1;
            }
        }

        fn run(self: *Self, io: std.Io, name: []const u8) !void {
            for (0..self.consumers) |id| self.threads[id] = try std.Thread.spawn(.{}, consume, .{ self, id });
            for (0..self.publishers) |id| self.threads[self.consumers + id] = try std.Thread.spawn(.{}, publish, .{ self, id });

            while (self.ready.load(.acquire) != self.threads.len) std.Thread.yield() catch {};
            const start = std.Io.Clock.awake.now(io);
            self.go.store(true, .release);
            for (self.threads) |thread| thread.join();
            const elapsed_ns = start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();

            const seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
            const total = self.publishers * self.per_publisher;
            const rate = @as(f64, @floatFromInt(total)) / seconds / 1e6;
            std.debug.print("{s:<17} {d:>3} {d:>3} {d:>8} {d:>10.3} {d:>10.3}  OK\n", .{
                name, self.publishers, self.consumers, total, seconds * 1000, rate,
            });
        }
    };
}

fn case(args: CliArgs, io: std.Io) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const disruptor = Disruptor(usize);

    var disruptor_bench = try Bench(disruptor).init(
        allocator,
        try disruptor.init(
            .{ .publisher_count = args.publishers, .consumer_count = args.consumers },
        ),
        args.publishers,
        args.consumers,
        args.events_per_publisher,
    );
    try disruptor_bench.run(io, "Disruptor");

    var queue_bench = try Bench(LockedQueue(usize)).init(
        allocator,
        try LockedQueue(usize).init(allocator, args.consumers),
        args.publishers,
        args.consumers,
        args.events_per_publisher,
    );
    try queue_bench.run(io, "QueueWithLocks");
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const args = try CliArgs.init(allocator, init.minimal);

    std.debug.print("M/s = million published items/s; every subscriber receives all items (order checked)\n", .{});
    std.debug.print("Queue             Pub Sub    Items         ms        M/s  Check\n", .{});
    std.debug.print("----------------------------------------------------------------\n", .{});
    try case(args, init.io);
}
