//
// ring_buffer.zig
//

const std = @import("std");
const atomic = std.atomic;

const testing = std.testing;
const mem = std.mem;

const PaddedSeq = struct {
    value: std.atomic.Value(usize) align(std.atomic.cache_line),
};

pub const EventBusError = error{
    InvalidConfig,
    InvalidConsumerID,
    IncorrectBufferSize,
    BusStopped,
    DuplicateStart,
};

pub fn RingBufferEventBus(
    comptime T: type,
    multi_producer: bool,
    event_handlers: []const *const fn (T) void,
) type {
    return struct {
        buffer: []T,
        buffer_seq: []atomic.Value(usize),
        cursor: *PaddedSeq,
        consumer_seq: []PaddedSeq,
        mask: usize,

        // Atomics to track thread lifecycle
        started: atomic.Value(bool) = .init(false),
        stopped: atomic.Value(bool) = .init(false),

        threads: []?std.Thread,
        allocator: mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, buffer_size: usize) !Self {
            // buffer_size must be a power of 2
            if (buffer_size == 0 or buffer_size & (buffer_size - 1) != 0) return EventBusError.IncorrectBufferSize;

            const buffer = try allocator.alloc(T, buffer_size);
            errdefer allocator.free(buffer);

            const buffer_seq = try allocator.alloc(atomic.Value(usize), buffer_size);
            errdefer allocator.free(buffer_seq);
            @memset(buffer_seq, .init(0));

            const cursor = try allocator.create(PaddedSeq);
            errdefer allocator.destroy(cursor);
            cursor.value = .init(1);

            const consumer_seq = try allocator.alloc(PaddedSeq, event_handlers.len);
            errdefer allocator.free(consumer_seq);
            @memset(consumer_seq, .{ .value = .init(1) });

            // TODO: Clip the number of threads to cpu count?
            const threads = try allocator.alloc(?std.Thread, event_handlers.len);
            errdefer allocator.free(threads);
            @memset(threads, null);

            return .{
                .buffer = buffer,
                .buffer_seq = buffer_seq,
                .cursor = cursor,
                .consumer_seq = consumer_seq,
                .mask = (buffer_size - 1),
                .threads = threads,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.allocator.free(self.buffer_seq);
            self.allocator.free(self.consumer_seq);
            self.allocator.destroy(self.cursor);
            self.allocator.free(self.threads);
        }

        pub fn start(self: *Self) !void {
            const started = self.started.load(.monotonic);
            if (started) return EventBusError.DuplicateStart;

            // this handles partial failures, the threads that were started
            // will receive the signal to stop.
            errdefer self.stop();

            for (0..event_handlers.len) |eid| {
                self.threads[eid] = try std.Thread.spawn(
                    .{ .allocator = self.allocator },
                    Self.handleEvent,
                    .{ self, eid },
                );
            }

            self.started.store(true, .release);
        }

        pub fn stop(self: *Self) void {
            self.stopped.store(true, .monotonic);

            for (self.threads) |th_| if (th_) |th| th.join();

            @memset(self.threads, null);
        }

        fn handleEvent(self: *Self, handler_id: usize) void {
            const handler = event_handlers[handler_id];
            var c_seq = self.consumer_seq[handler_id].value.load(.monotonic);
            var stopped = false;
            var started = false;

            // waiting for start
            while (!started and !stopped) {
                stopped = self.stopped.load(.monotonic);
                started = self.started.load(.monotonic);
            }

            while (!stopped) : (stopped = self.stopped.load(.monotonic)) {
                const buffer_seq = self.buffer_seq[(c_seq & self.mask)].load(.acquire);

                if (buffer_seq == 0 or c_seq > buffer_seq) continue;

                const event = self.buffer[(c_seq & self.mask)];

                handler(event);

                c_seq += 1;
                self.consumer_seq[handler_id].value.store(c_seq, .release);
            }

            const cursor = self.cursor.value.load(.monotonic);

            while (c_seq < cursor) {
                const buffer_seq = self.buffer_seq[(c_seq & self.mask)].load(.acquire);

                if (buffer_seq == 0 or c_seq > buffer_seq) break;

                const event = self.buffer[(c_seq & self.mask)];

                handler(event);

                c_seq += 1;
                self.consumer_seq[handler_id].value.store(c_seq, .release);
            }
        }

        pub fn produce(self: *Self, event: T) !void {
            const stopped = self.stopped.load(.monotonic);

            if (stopped) return EventBusError.BusStopped;

            const produce_fn = if (multi_producer) Self.multi_producer_produce else Self.single_producer_produce;
            try produce_fn(self, event);
        }

        fn multi_producer_produce(self: *Self, event: T) !void {
            _ = self;
            _ = event;
            @panic("todo!");
        }

        fn single_producer_produce(self: *Self, event: T) !void {
            const claimed_seq = self.cursor.value.fetchAdd(1, .monotonic);
            const buffer_idx = (claimed_seq & self.mask);
            if (!self.isSlotSafeToWrite(claimed_seq)) @panic("Implement producer waiting strategy!");

            self.buffer[buffer_idx] = event;
            self.buffer_seq[buffer_idx].store(claimed_seq, .release);
        }

        fn isSlotSafeToWrite(self: *Self, seq: usize) bool {
            // Here we check that the slowest consumer sequence is strictly
            // greater than `seq - buffer_size`, for the reasons as follows
            //
            // We want to make sure that the slot is safe is write i.e
            // All the consumers have consumed the data from the slot as well as
            // no other publisher have acquire the slot but haven't  released it yet.
            for (0..self.consumer_seq.len) |c| {
                const c_seq = &self.consumer_seq[c];
                const consumed_till = c_seq.value.load(.acquire);
                if (consumed_till <= std.math.sub(usize, seq, self.buffer.len) catch 0) {
                    return false;
                }
            }
            return true;
        }
    };
}

fn createIntEventHandler(comptime size: usize, comptime thread: usize) type {
    return struct {
        var out: [size]?usize = @splat(null);
        var written: usize = 0;
        //TODO: This is a hack to get compiler to
        // crearte new types, zig will reuse same type if the arguments are same.
        // I need to add a callback or something to the handler signature
        // to handle this properly.
        var id = thread;

        fn handler(event: usize) void {
            out[written] = event;
            written += 1;
        }
    };
}

test "Ring buffer init" {
    const allocator = testing.allocator;

    const handlers = [_]*const fn (usize) void{
        createIntEventHandler(1, 9).handler,
    };

    var eb = try RingBufferEventBus(usize, false, &handlers).init(allocator, 1024);
    defer eb.deinit();

    try testing.expectError(EventBusError.IncorrectBufferSize, RingBufferEventBus(
        usize,
        false,
        &handlers,
    ).init(allocator, 120));
}

test "DuplicateStart" {
    const allocator = testing.allocator;

    const handlers = [_]*const fn (usize) void{
        createIntEventHandler(1, 9).handler,
    };

    var eb = try RingBufferEventBus(usize, false, &handlers).init(allocator, 1024);
    defer eb.deinit();

    try eb.start();
    defer eb.stop();

    try testing.expectError(EventBusError.DuplicateStart, eb.start());
}

test "single producer tests" {
    const allocator = testing.allocator;

    const handler_struct = [_]type{
        createIntEventHandler(10, 0),
        createIntEventHandler(10, 1),
        createIntEventHandler(10, 2),
        createIntEventHandler(10, 3),
    };
    const handlers: [4]*const fn (usize) void = .{
        handler_struct[0].handler,
        handler_struct[1].handler,
        handler_struct[2].handler,
        handler_struct[3].handler,
    };

    var bus = try RingBufferEventBus(usize, false, &handlers).init(allocator, 16);
    defer bus.deinit();

    try testing.expectEqual(bus.started.raw, false);
    try testing.expectEqual(bus.stopped.raw, false);

    try bus.start();

    try testing.expectEqual(bus.started.raw, true);
    try testing.expectEqual(bus.stopped.raw, false);

    for (0..10) |i| {
        try bus.produce(i);
    }

    bus.stop();

    try testing.expectEqual(bus.started.raw, true);
    try testing.expectEqual(bus.stopped.raw, true);

    inline for (0..4) |hs| {
        for (handler_struct[hs].out, 0..) |out, exp| {
            try testing.expectEqual(exp, out);
        }
    }
}
