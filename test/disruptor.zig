const std = @import("std");
const Disruptor = @import("zigrupt").Disruptor;

test "single consumer reads in order across buffer wraps" {
    var queue = try Disruptor(usize).init(.{ .consumer_count = 1 });
    try std.testing.expectEqual(null, queue.consume(0));

    for (0..4) |batch| {
        for (0..queue.buffer.len) |offset| queue.publish(batch * queue.buffer.len + offset);
        for (0..queue.buffer.len) |offset| {
            try std.testing.expectEqual(@as(?usize, batch * queue.buffer.len + offset), queue.consume(0));
        }
        try std.testing.expectEqual(null, queue.consume(0));
    }
}

test "each consumer receives the same items independently" {
    var queue = try Disruptor(u8).init(.{ .consumer_count = 2 });
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

const BackpressureQueue = Disruptor(usize);

fn publishWhenReady(queue: *BackpressureQueue, started: *std.atomic.Value(bool), finished: *std.atomic.Value(bool)) void {
    started.store(true, .release);
    queue.publish(queue.buffer.len);
    finished.store(true, .release);
}

test "slow subscriber prevents overwriting an unread slot" {
    var queue = try BackpressureQueue.init(.{ .consumer_count = 2 });
    for (0..queue.buffer.len) |value| queue.publish(value);
    for (0..queue.buffer.len) |value| try std.testing.expectEqual(@as(?usize, value), queue.consume(0));

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
    try std.testing.expectEqual(@as(?usize, 0), first);
    try std.testing.expectEqual(@as(?usize, queue.buffer.len), queue.consume(0));
    for (1..queue.buffer.len + 1) |value| try std.testing.expectEqual(@as(?usize, value), queue.consume(1));
}

const items_per_publisher = 128;
const total_items = 2 * items_per_publisher;
const ConcurrentQueue = Disruptor(usize);

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
    var queue = try ConcurrentQueue.init(.{ .consumer_count = 2, .publisher_count = 2 });
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
