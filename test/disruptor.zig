const std = @import("std");
const Disruptor = @import("zigrupt").Disruptor;

test "single consumer reads in order across buffer wraps" {
    var queue: Disruptor(u8, .{ .buffer_size = 4, .consumer_count = 1 }) = .{};
    try std.testing.expectEqual(null, queue.consume(0));

    for (0..4) |batch| {
        for (0..4) |offset| queue.publish(@intCast(batch * 4 + offset));
        for (0..4) |offset| {
            try std.testing.expectEqual(@as(?u8, @intCast(batch * 4 + offset)), queue.consume(0));
        }
        try std.testing.expectEqual(null, queue.consume(0));
    }
}

test "each consumer receives the same items independently" {
    var queue: Disruptor(u8, .{ .buffer_size = 4, .consumer_count = 2 }) = .{};
    for (0..4) |value| queue.publish(@intCast(value));

    for (0..4) |value| {
        try std.testing.expectEqual(@as(?u8, @intCast(value)), queue.consume(0));
    }
    for (0..4) |value| {
        try std.testing.expectEqual(@as(?u8, @intCast(value)), queue.consume(1));
    }
    try std.testing.expectEqual(null, queue.consume(0));
    try std.testing.expectEqual(null, queue.consume(1));
}

const BackpressureQueue = Disruptor(u8, .{ .buffer_size = 4, .consumer_count = 2 });

fn publishWhenReady(queue: *BackpressureQueue, started: *std.atomic.Value(bool), finished: *std.atomic.Value(bool)) void {
    started.store(true, .release);
    queue.publish(4);
    finished.store(true, .release);
}

test "slow subscriber prevents overwriting an unread slot" {
    var queue: BackpressureQueue = .{};
    for (0..4) |value| queue.publish(@intCast(value));
    for (0..4) |value| try std.testing.expectEqual(@as(?u8, @intCast(value)), queue.consume(0));

    var started = std.atomic.Value(bool).init(false);
    var finished = std.atomic.Value(bool).init(false);
    const publisher = try std.Thread.spawn(.{}, publishWhenReady, .{ &queue, &started, &finished });
    while (!started.load(.acquire)) std.Thread.yield() catch {};
    // Give the publisher time to attempt the write while subscriber 1 is stalled.
    for (0..100) |_| std.Thread.yield() catch {};
    const finished_early = finished.load(.acquire);

    const first = queue.consume(1);
    publisher.join();
    try std.testing.expect(!finished_early);
    try std.testing.expectEqual(@as(?u8, 0), first);
    try std.testing.expectEqual(@as(?u8, 4), queue.consume(0));
    for (1..5) |value| try std.testing.expectEqual(@as(?u8, @intCast(value)), queue.consume(1));
}

const items_per_publisher = 128;
const total_items = 2 * items_per_publisher;
const ConcurrentQueue = Disruptor(usize, .{
    .buffer_size = 8,
    .consumer_count = 2,
    .publisher_count = 2,
});

fn publishRange(queue: *ConcurrentQueue, start: usize) void {
    for (start..start + items_per_publisher) |value| queue.publish(value);
}

fn collect(queue: *ConcurrentQueue, id: usize, items: *[total_items]usize) void {
    var count: usize = 0;
    while (count < items.len) {
        if (queue.consume(id)) |value| {
            items[count] = value;
            count += 1;
        }
    }
}

test "concurrent publishers and subscribers preserve every publisher's order" {
    var queue: ConcurrentQueue = .{};
    var first_items: [total_items]usize = undefined;
    var second_items: [total_items]usize = undefined;

    const first_subscriber = try std.Thread.spawn(.{}, collect, .{ &queue, 0, &first_items });
    const second_subscriber = try std.Thread.spawn(.{}, collect, .{ &queue, 1, &second_items });
    const first_publisher = try std.Thread.spawn(.{}, publishRange, .{ &queue, 0 });
    const second_publisher = try std.Thread.spawn(.{}, publishRange, .{ &queue, items_per_publisher });

    first_publisher.join();
    second_publisher.join();
    first_subscriber.join();
    second_subscriber.join();

    for ([_]*[total_items]usize{ &first_items, &second_items }) |items| {
        var next = [_]usize{ 0, 0 };
        for (items) |value| {
            try std.testing.expect(value < total_items);
            const publisher = value / items_per_publisher;
            try std.testing.expectEqual(next[publisher], value % items_per_publisher);
            next[publisher] += 1;
        }
        try std.testing.expectEqual([_]usize{ items_per_publisher, items_per_publisher }, next);
    }
    try std.testing.expectEqual(null, queue.consume(0));
    try std.testing.expectEqual(null, queue.consume(1));
}
