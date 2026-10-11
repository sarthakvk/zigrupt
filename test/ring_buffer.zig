//! Sequence-indexed storage, slot reuse, and contiguous slice tests.

const std = @import("std");
const RingBuffer = @import("zigrupt").RingBuffer;

test "ring buffer accepts nonzero power-of-two capacities" {
    for ([_]usize{ 1, 2, 8, 1024 }) |capacity| {
        var ring = try RingBuffer(usize).init(std.testing.allocator, capacity);
        defer ring.deinit();

        try std.testing.expectEqual(capacity, ring.buffer.len);
        try std.testing.expectEqual(capacity - 1, ring.mask);
    }
}

test "ring buffer rejects invalid capacities before allocating" {
    // The allocator would fail if reached, making validation order observable.
    for ([_]usize{ 0, 3, 7, 120, std.math.maxInt(usize) }) |capacity| {
        try std.testing.expectError(error.IncorrectBufferSize, RingBuffer(usize).init(std.testing.failing_allocator, capacity));
    }
}

test "ring buffer propagates allocation failure" {
    try std.testing.expectError(error.OutOfMemory, RingBuffer(usize).init(std.testing.failing_allocator, 8));
}

test "ring buffer saves and retrieves sequences across multiple wraps" {
    for ([_]usize{ 1, 2, 8 }) |capacity| {
        var ring = try RingBuffer(usize).init(std.testing.allocator, capacity);
        defer ring.deinit();

        const view: *const RingBuffer(usize) = &ring;
        for (0..4) |lap| {
            const start = lap * capacity + 1;
            // Fill and inspect one complete lap before overwriting it. The payload
            // encodes the sequence so a stale value cannot satisfy the next lap's check.
            for (start..start + capacity) |sequence| ring.save(sequence, sequence * 10);
            for (start..start + capacity) |sequence| {
                try std.testing.expectEqual(sequence * 10, view.get(sequence).*);
            }
        }
        try std.testing.expectEqual(*const usize, @TypeOf(view.get(1)));
    }
}

test "ring buffer sequence aliases refer to reusable slots, not historical events" {
    var ring = try RingBuffer(usize).init(std.testing.allocator, 8);
    defer ring.deinit();

    ring.save(1, 10);
    const slot: *const usize = ring.get(1);
    // Sequences one capacity apart alias. A retained pointer observes the overwrite,
    // and looking up the older sequence returns the current slot value too.
    ring.save(9, 90);
    try std.testing.expectEqual(slot, ring.get(9));
    try std.testing.expectEqual(@as(usize, 90), slot.*);
    try std.testing.expectEqual(@as(usize, 90), ring.get(1).*);

    // Storage accepts sequence zero and upper-bound values as indices; these are
    // masking checks, not permission for an event-bus sequence counter to overflow.
    ring.save(0, 80);
    try std.testing.expectEqual(@as(usize, 80), ring.get(8).*);
    const last = std.math.maxInt(usize);
    ring.save(last, 70);
    try std.testing.expectEqual(@as(usize, 70), ring.get(last).*);
    try std.testing.expectEqual(ring.get(7), ring.get(last));
}

test "ring buffer slices are bounded by the requested length and physical boundary" {
    for ([_]usize{ 1, 2, 8 }) |capacity| {
        var ring = try RingBuffer(usize).init(std.testing.allocator, capacity);
        defer ring.deinit();
        // Initialize each slot with its physical index. Later logical laps should
        // borrow these same addresses and values, not synthesize a wrapped slice.
        for (0..capacity) |sequence| ring.save(sequence, sequence);

        const view: *const RingBuffer(usize) = &ring;
        for (0..capacity * 3) |sequence| {
            const index = sequence & (capacity - 1);
            for ([_]usize{ 0, 1, capacity - 1, capacity, capacity + 1, std.math.maxInt(usize) }) |max_len| {
                const events: []const usize = view.slice(sequence, max_len);
                try std.testing.expectEqual(@min(max_len, capacity - index), events.len);
                try std.testing.expectEqual(@as([*]const usize, @ptrCast(view.get(sequence))), events.ptr);
                for (events, index..) |value, expected| try std.testing.expectEqual(expected, value);
            }
        }
        try std.testing.expectEqual([]const usize, @TypeOf(view.slice(0, 1)));
        try std.testing.expectEqualSlices(usize, &.{capacity - 1}, view.slice(std.math.maxInt(usize), std.math.maxInt(usize)));
    }
}

test "ring buffer copies event values but does not own referenced resources" {
    const Event = struct { id: usize, data: []const u8 };
    var ring = try RingBuffer(Event).init(std.testing.allocator, 2);
    defer ring.deinit();

    var data = [_]u8{ 1, 2, 3 };
    var event: Event = .{ .id = 42, .data = &data };
    ring.save(1, event);
    // Mutating the source struct must not change its copied scalar field. Mutating
    // the referenced bytes must remain visible through the shallow-copied slice.
    event.id = 99;
    data[0] = 9;

    try std.testing.expectEqual(@as(usize, 42), ring.get(1).id);
    try std.testing.expectEqualSlices(u8, &.{ 9, 2, 3 }, ring.get(1).data);
    try std.testing.expectEqual(@as([*]const u8, &data), ring.get(1).data.ptr);
}
