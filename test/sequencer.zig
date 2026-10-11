//! Sequence coordination tests without event storage or handler threads.

const std = @import("std");
const Sequencer = @import("zigrupt").sequencer.Sequencer;
const Gate = @import("support/synchronization.zig").Gate;
const Counter = @import("support/synchronization.zig").Counter;

fn cachedLimit(comptime multi_producer: bool, coordinator: *const Sequencer(multi_producer)) usize {
    return if (multi_producer) coordinator.claim_policy.safe_to_write_through.value.load(.acquire) else coordinator.claim_policy.safe_to_write_through;
}

test "sequencer starts with unpublished slots and next-unread consumers at one" {
    inline for (.{ false, true }) |multi_producer| {
        for ([_]usize{ 1, 8 }) |capacity| {
            var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, capacity, capacity, 2);
            defer coordinator.deinit();

            try std.testing.expectEqual(capacity, coordinator.max_consumer_batch_size);
            try std.testing.expectEqual(1, coordinator.nextClaimSequence());
            try std.testing.expectEqual(capacity - 1, coordinator.mask);
            for (0..2) |consumer_id| {
                try std.testing.expectEqual(1, coordinator.consumerSequence(consumer_id, .monotonic));
            }
            for (coordinator.buffer_seq) |*marker| try std.testing.expectEqual(0, marker.load(.acquire));
            try std.testing.expectEqual(0, coordinator.publishedBatchSize(0, null));
            for (1..capacity + 3) |sequence| try std.testing.expectEqual(sequence, coordinator.claim());
            try std.testing.expectEqual(capacity + 3, coordinator.nextClaimSequence());
            try std.testing.expectEqual(0, coordinator.publishedBatchSize(1, null));
        }
        for ([_]usize{ 0, 3, 120 }) |capacity| {
            try std.testing.expectError(error.IncorrectBufferSize, Sequencer(multi_producer).init(std.testing.failing_allocator, capacity, 1, 2));
        }
    }
}

test "sequencer batch size must be nonzero and no larger than capacity" {
    inline for (.{ false, true }) |multi_producer| {
        for ([_]usize{ 1, 8 }) |capacity| {
            try std.testing.expectError(error.IncorrectBatchSize, Sequencer(multi_producer).init(std.testing.failing_allocator, capacity, 0, 1));
            try std.testing.expectError(error.IncorrectBatchSize, Sequencer(multi_producer).init(std.testing.failing_allocator, capacity, capacity + 1, 1));
            for (1..capacity + 1) |max_batch| {
                var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, capacity, max_batch, 1);
                defer coordinator.deinit();
                try std.testing.expectEqual(max_batch, coordinator.max_consumer_batch_size);
            }
        }
    }
}

test "sequencer frees coordination storage when allocation fails" {
    inline for (.{ false, true }) |multi_producer| {
        const Check = struct {
            fn initAndDeinit(allocator: std.mem.Allocator) !void {
                var coordinator = try Sequencer(multi_producer).init(allocator, 8, 8, 2);
                defer coordinator.deinit();
            }
        };
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.initAndDeinit, .{});
    }
}

test "write safety limit caches the slowest consumer's progress" {
    inline for (.{ false, true }) |multi_producer| {
        for ([_]usize{ 1, 8 }) |capacity| {
            var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, capacity, capacity, 2);
            defer coordinator.deinit();

            try std.testing.expectEqual(capacity, cachedLimit(multi_producer, &coordinator));
            try std.testing.expect(coordinator.isSlotSafeToWrite(capacity));
            try std.testing.expect(!coordinator.isSlotSafeToWrite(capacity + 1));

            coordinator.acknowledge(0, 5);
            try std.testing.expect(!coordinator.isSlotSafeToWrite(capacity + 1));

            coordinator.acknowledge(1, 3);
            try std.testing.expect(coordinator.isSlotSafeToWrite(capacity + 1));
            try std.testing.expectEqual(capacity + 2, cachedLimit(multi_producer, &coordinator));

            coordinator.acknowledge(1, 7);
            try std.testing.expect(coordinator.isSlotSafeToWrite(capacity + 2));
            // Cache hits do not refresh the limit even when consumers advanced.
            try std.testing.expectEqual(capacity + 2, cachedLimit(multi_producer, &coordinator));

            try std.testing.expect(coordinator.isSlotSafeToWrite(capacity + 4));
            try std.testing.expectEqual(capacity + 4, cachedLimit(multi_producer, &coordinator));
            try std.testing.expect(!coordinator.isSlotSafeToWrite(capacity + 5));
        }
    }
}

test "write safety limit handles no consumers and the sequence upper bound" {
    inline for (.{ false, true }) |multi_producer| {
        for ([_]usize{ 1, 8 }) |capacity| {
            for (0..2) |consumer_count| {
                var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, capacity, capacity, consumer_count);
                defer coordinator.deinit();

                for (0..consumer_count) |consumer_id| coordinator.acknowledge(consumer_id, std.math.maxInt(usize));
                try std.testing.expect(coordinator.isSlotSafeToWrite(std.math.maxInt(usize)));
                try std.testing.expectEqual(std.math.maxInt(usize), cachedLimit(multi_producer, &coordinator));
            }
        }
        var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, 8, 8, 1);
        defer coordinator.deinit();
        coordinator.acknowledge(0, std.math.maxInt(usize) - 1);
        try std.testing.expect(coordinator.isSlotSafeToWrite(std.math.maxInt(usize)));
        try std.testing.expectEqual(std.math.maxInt(usize), cachedLimit(multi_producer, &coordinator));
    }
}

test "published batches stop at the first gap and require the exact sequence marker" {
    inline for (.{ false, true }) |multi_producer| {
        var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, 8, 8, 1);
        defer coordinator.deinit();

        coordinator.publish(2);
        coordinator.publish(4);
        try std.testing.expectEqual(0, coordinator.publishedBatchSize(1, null));
        coordinator.publish(1);
        try std.testing.expectEqual(2, coordinator.publishedBatchSize(1, null));
        try std.testing.expectEqual(0, coordinator.publishedBatchSize(3, null));
        try std.testing.expectEqual(1, coordinator.publishedBatchSize(4, null));
        coordinator.publish(3);
        try std.testing.expectEqual(4, coordinator.publishedBatchSize(1, null));

        // Previous-lap markers cannot expose events for a newly reused slot.
        try std.testing.expectEqual(0, coordinator.publishedBatchSize(9, null));
        coordinator.publish(9);
        try std.testing.expectEqual(0, coordinator.publishedBatchSize(9, 8));
        try std.testing.expectEqual(0, coordinator.publishedBatchSize(9, 9));
        coordinator.publish(11);
        try std.testing.expectEqual(1, coordinator.publishedBatchSize(9, null));
        coordinator.publish(10);
        try std.testing.expectEqual(3, coordinator.publishedBatchSize(9, null));
        // A newer marker must not be accepted for an older expected sequence either.
        try std.testing.expectEqual(0, coordinator.publishedBatchSize(1, null));
    }
}

test "published batches honor size, physical boundaries and exclusive drain ends" {
    inline for (.{ false, true }) |multi_producer| {
        for ([_]usize{ 1, 8 }) |capacity| {
            for (1..capacity + 1) |max_consumer_batch_size| {
                var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, capacity, max_consumer_batch_size, 1);
                defer coordinator.deinit();
                for (1..capacity + 1) |sequence| coordinator.publish(sequence);

                const contiguous = @min(max_consumer_batch_size, if (capacity == 1) 1 else capacity - 1);
                try std.testing.expectEqual(max_consumer_batch_size, coordinator.max_consumer_batch_size);
                try std.testing.expectEqual(contiguous, coordinator.publishedBatchSize(1, null));
                try std.testing.expectEqual(1, coordinator.publishedBatchSize(capacity, null));
                try std.testing.expectEqual(0, coordinator.publishedBatchSize(1, 0));
                try std.testing.expectEqual(0, coordinator.publishedBatchSize(1, 1));
                try std.testing.expectEqual(1, coordinator.publishedBatchSize(1, 2));
                try std.testing.expectEqual(contiguous, coordinator.publishedBatchSize(1, capacity + 1));
            }
        }
    }
}

test "concurrent multi-producer claims are unique and later publication cannot hide a gap" {
    const producer_count = 4;
    const claims_per_producer = 32;
    const count = producer_count * claims_per_producer;
    const Worker = struct {
        fn run(coordinator: *Sequencer(true), gate: *Gate, ready: *Counter, claims: *[claims_per_producer]usize) void {
            ready.increment();
            gate.wait();
            for (claims) |*sequence| {
                sequence.* = coordinator.claim();
                coordinator.publish(sequence.*);
            }
        }
    };

    var coordinator = try Sequencer(true).init(std.testing.allocator, 256, 256, 1);
    defer coordinator.deinit();
    const gap = coordinator.claim();
    var gate: Gate = .{};
    var ready: Counter = .{};
    var claims: [producer_count][claims_per_producer]usize = undefined;
    var threads: [producer_count]std.Thread = undefined;
    var started: usize = 0;
    defer {
        gate.open();
        for (threads[0..started]) |thread| thread.join();
    }
    for (&threads, &claims) |*thread, *sequences| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &coordinator, &gate, &ready, sequences });
        started += 1;
    }
    ready.waitFor(producer_count);
    gate.open();
    for (threads[0..started]) |thread| thread.join();
    started = 0;

    var seen: [count]bool = @splat(false);
    for (claims) |sequences| {
        for (sequences) |sequence| {
            try std.testing.expect(sequence >= 2 and sequence <= count + 1);
            try std.testing.expect(!seen[sequence - 2]);
            seen[sequence - 2] = true;
        }
    }
    for (seen) |claimed| try std.testing.expect(claimed);
    try std.testing.expectEqual(count + 2, coordinator.nextClaimSequence());
    try std.testing.expectEqual(0, coordinator.publishedBatchSize(gap, null));
    try std.testing.expectEqual(count, coordinator.publishedBatchSize(gap + 1, null));
    coordinator.publish(gap);
    try std.testing.expectEqual(count + 1, coordinator.publishedBatchSize(gap, coordinator.nextClaimSequence()));
}

test "multi-producer capacity cache does not regress under concurrent checks" {
    const producer_count = 4;
    const progress_end = 1024;
    const capacity = 8;
    const Worker = struct {
        fn run(coordinator: *Sequencer(true), gate: *Gate, ready: *Counter, completed: *Counter) void {
            ready.increment();
            gate.wait();
            while (true) {
                const next_unread = coordinator.consumerSequence(0, .acquire);
                std.debug.assert(coordinator.isSlotSafeToWrite(next_unread + capacity - 1));
                if (next_unread == progress_end) break;
            }
            completed.increment();
        }
    };

    var coordinator = try Sequencer(true).init(std.testing.allocator, capacity, capacity, 1);
    defer coordinator.deinit();
    var gate: Gate = .{};
    var ready: Counter = .{};
    var completed: Counter = .{};
    var threads: [producer_count]std.Thread = undefined;
    var started: usize = 0;
    defer {
        coordinator.acknowledge(0, progress_end);
        gate.open();
        for (threads[0..started]) |thread| thread.join();
    }
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &coordinator, &gate, &ready, &completed });
        started += 1;
    }
    ready.waitFor(producer_count);
    gate.open();
    var previous = cachedLimit(true, &coordinator);
    for (2..progress_end + 1) |next_unread| {
        coordinator.acknowledge(0, next_unread);
        const current = cachedLimit(true, &coordinator);
        try std.testing.expect(current >= previous);
        previous = current;
    }
    completed.waitFor(producer_count);
    try std.testing.expectEqual(progress_end + capacity - 1, cachedLimit(true, &coordinator));
}
