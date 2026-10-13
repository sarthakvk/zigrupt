//! Sequence coordination tests without event storage or handler threads.

const std = @import("std");
const Sequencer = @import("zigrupt").sequencer.Sequencer;
const Gate = @import("support/synchronization.zig").Gate;
const Counter = @import("support/synchronization.zig").Counter;

/// Reads the policy's inclusive safe-to-write limit without refreshing it.
///
/// Single-producer reads occur on the owning test thread. The shared multi-producer
/// cache is read atomically so observers can inspect it while workers update it.
fn cachedLimit(comptime multi_producer: bool, coordinator: *const Sequencer(multi_producer)) usize {
    return if (multi_producer) coordinator.claim_policy.safe_to_write_through.value.load(.acquire) else coordinator.claim_policy.safe_to_write_through;
}

test "sequencer starts with unpublished slots and next-unread consumers at one" {
    inline for (.{ false, true }) |multi_producer| {
        for (0..20) |exp| {
            const capacity = std.math.pow(usize, 2, exp);
            var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, capacity);
            defer coordinator.deinit();

            try std.testing.expect(coordinator.consumer_seq == null);
            try coordinator.initConsumers(2);
            try std.testing.expectEqual(1, coordinator.nextClaimSequence());
            try std.testing.expectEqual(capacity - 1, coordinator.mask);
            for (0..2) |consumer_id| {
                try std.testing.expectEqual(1, try coordinator.consumerSequence(consumer_id, .monotonic));
            }
            for (coordinator.buffer_seq) |*marker| try std.testing.expectEqual(0, marker.load(.acquire));
            try std.testing.expectEqual(0, coordinator.publishedBatchSize(0, capacity));
            // Claiming neither waits for capacity nor publishes a marker, even when
            // the reserved sequence range extends beyond the initial writable lap.
            for (1..capacity + 3) |sequence| try std.testing.expectEqual(sequence, coordinator.claim());
            try std.testing.expectEqual(capacity + 3, coordinator.nextClaimSequence());
            try std.testing.expectEqual(0, coordinator.publishedBatchSize(1, capacity));
        }
        for (0..1000) |capacity| {
            if (capacity > 0 and (capacity & (capacity - 1) == 0)) continue;
            try std.testing.expectError(error.IncorrectBufferSize, Sequencer(multi_producer).init(std.testing.failing_allocator, capacity));
        }
    }
}

test "sequencer frees coordination storage when allocation fails" {
    inline for (.{ false, true }) |multi_producer| {
        const Check = struct {
            /// Lets the allocation-failure harness exercise cleanup at every allocation.
            fn initAndDeinit(allocator: std.mem.Allocator) !void {
                var coordinator = try Sequencer(multi_producer).init(allocator, 8);
                defer coordinator.deinit();
                try coordinator.initConsumers(2);
            }
        };
        try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.initAndDeinit, .{});
    }
}

test "write safety limit caches the slowest consumer's progress" {
    inline for (.{ false, true }) |multi_producer| {
        for ([_]usize{ 1, 8 }) |capacity| {
            var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, capacity);
            defer coordinator.deinit();
            try coordinator.initConsumers(2);

            try std.testing.expectEqual(capacity, cachedLimit(multi_producer, &coordinator));
            try std.testing.expect(try coordinator.isSlotSafeToWrite(capacity));
            try std.testing.expect(!try coordinator.isSlotSafeToWrite(capacity + 1));

            // Consumer 1 still needs sequence 1; advancing consumer 0 cannot free it.
            try coordinator.acknowledge(0, 5);
            try std.testing.expect(!try coordinator.isSlotSafeToWrite(capacity + 1));

            // The inclusive write limit is slowest next-unread + capacity - 1.
            // With the slowest cursor at 3, two additional writes beyond the initial lap are safe.
            try coordinator.acknowledge(1, 3);
            try std.testing.expect(try coordinator.isSlotSafeToWrite(capacity + 1));
            try std.testing.expectEqual(capacity + 2, cachedLimit(multi_producer, &coordinator));

            try coordinator.acknowledge(1, 7);
            try std.testing.expect(try coordinator.isSlotSafeToWrite(capacity + 2));
            // Cache hits do not refresh the limit even when consumers advanced.
            try std.testing.expectEqual(capacity + 2, cachedLimit(multi_producer, &coordinator));

            try std.testing.expect(try coordinator.isSlotSafeToWrite(capacity + 4));
            try std.testing.expectEqual(capacity + 4, cachedLimit(multi_producer, &coordinator));
            try std.testing.expect(!try coordinator.isSlotSafeToWrite(capacity + 5));
        }
    }
}

test "write safety limit handles no consumers and the sequence upper bound" {
    inline for (.{ false, true }) |multi_producer| {
        for ([_]usize{ 1, 8 }) |capacity| {
            for (0..2) |consumer_count| {
                var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, capacity);
                defer coordinator.deinit();
                try coordinator.initConsumers(consumer_count);

                // No consumers removes backpressure. A consumer at the upper bound
                // exercises the same saturated limit, not permission for claims to overflow.
                for (0..consumer_count) |consumer_id| try coordinator.acknowledge(consumer_id, std.math.maxInt(usize));
                try std.testing.expect(try coordinator.isSlotSafeToWrite(std.math.maxInt(usize)));
                try std.testing.expectEqual(std.math.maxInt(usize), cachedLimit(multi_producer, &coordinator));
            }
        }
        var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, 8);
        defer coordinator.deinit();
        try coordinator.initConsumers(1);
        try coordinator.acknowledge(0, std.math.maxInt(usize) - 1);
        try std.testing.expect(try coordinator.isSlotSafeToWrite(std.math.maxInt(usize)));
        try std.testing.expectEqual(std.math.maxInt(usize), cachedLimit(multi_producer, &coordinator));
    }
}

test "published batches stop at the first gap and require the exact sequence marker" {
    inline for (.{ false, true }) |multi_producer| {
        var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, 8);
        defer coordinator.deinit();
        try coordinator.initConsumers(1);

        // Publishing later sequences cannot make the missing prefix visible. Markers
        // are driven directly here; slot ownership and event writes are outside this test.
        coordinator.publish(2);
        coordinator.publish(4);
        try std.testing.expectEqual(0, coordinator.publishedBatchSize(1, 8));
        coordinator.publish(1);
        try std.testing.expectEqual(2, coordinator.publishedBatchSize(1, 8));
        try std.testing.expectEqual(0, coordinator.publishedBatchSize(3, 8));
        try std.testing.expectEqual(1, coordinator.publishedBatchSize(4, 8));
        coordinator.publish(3);
        try std.testing.expectEqual(4, coordinator.publishedBatchSize(1, 8));

        // Previous-lap markers cannot expose events for a newly reused slot.
        try std.testing.expectEqual(0, coordinator.publishedBatchSize(9, 8));
        coordinator.publish(9);
        coordinator.publish(11);
        try std.testing.expectEqual(1, coordinator.publishedBatchSize(9, 8));
        coordinator.publish(10);
        try std.testing.expectEqual(3, coordinator.publishedBatchSize(9, 8));
        // A newer marker must not be accepted for an older expected sequence either.
        try std.testing.expectEqual(0, coordinator.publishedBatchSize(1, 8));
    }
}

test "published batches honor size and physical boundaries" {
    inline for (.{ false, true }) |multi_producer| {
        for ([_]usize{ 1, 8 }) |capacity| {
            var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, capacity);
            defer coordinator.deinit();
            try coordinator.initConsumers(1);
            for (1..capacity + 1) |sequence| coordinator.publish(sequence);

            // Sequence 1 maps to index 1 except in a one-slot ring. The last sequence
            // of the lap maps to index zero and therefore needs a separate batch.
            const contiguous = if (capacity == 1) 1 else capacity - 1;
            try std.testing.expectEqual(contiguous, coordinator.publishedBatchSize(1, capacity + 5));
            try std.testing.expectEqual(1, coordinator.publishedBatchSize(capacity, capacity));
            try std.testing.expectEqual(0, coordinator.publishedBatchSize(1, 0));
            for (0..capacity + 1) |max_count| {
                try std.testing.expectEqual(@min(max_count, contiguous), coordinator.publishedBatchSize(1, max_count));
            }
        }
    }
}

test "published batches stop at the first unclaimed sequence after producers finish" {
    inline for (.{ false, true }) |multi_producer| {
        const capacity = 8;
        var coordinator = try Sequencer(multi_producer).init(std.testing.allocator, capacity);
        defer coordinator.deinit();
        try coordinator.initConsumers(1);

        // Leave a full lap of old markers, then acknowledge it so the next lap can
        // reuse slots. Only its first three sequences receive fresh publications.
        for (0..capacity) |_| coordinator.publish(coordinator.claim());
        const start_sequence = coordinator.nextClaimSequence();
        try coordinator.acknowledge(0, start_sequence);

        const published_count = 3;
        for (0..published_count) |_| {
            const sequence = coordinator.claim();
            try std.testing.expect(try coordinator.isSlotSafeToWrite(sequence));
            coordinator.publish(sequence);
        }
        const cursor = coordinator.nextClaimSequence();
        try std.testing.expectEqual(start_sequence + published_count, cursor);
        // The cursor's slot is initialized but stale. A scan must stop there instead
        // of treating the previous lap's marker as another queued event.
        try std.testing.expectEqual(cursor - capacity, coordinator.buffer_seq[cursor & coordinator.mask].load(.acquire));
        try std.testing.expectEqual(published_count, coordinator.publishedBatchSize(start_sequence, capacity));
        try std.testing.expectEqual(0, coordinator.publishedBatchSize(cursor, capacity));
    }
}

test "concurrent multi-producer claims are unique and later publication cannot hide a gap" {
    const producer_count = 4;
    const claims_per_producer = 32;
    const count = producer_count * claims_per_producer;
    const Worker = struct {
        /// Records this worker's claims in its own array and immediately publishes each one.
        ///
        /// The owner reads arrays only after join; the gate starts all workers together.
        fn run(coordinator: *Sequencer(true), gate: *Gate, ready: *Counter, claims: *[claims_per_producer]usize) void {
            ready.increment();
            gate.wait();
            for (claims) |*sequence| {
                sequence.* = coordinator.claim();
                coordinator.publish(sequence.*);
            }
        }
    };

    // Capacity exceeds all claims, avoiding slot aliasing so this test isolates claim
    // uniqueness and contiguous publication rather than backpressure or wraparound.
    var coordinator = try Sequencer(true).init(std.testing.allocator, 256);
    defer coordinator.deinit();
    try coordinator.initConsumers(1);
    // Reserve sequence 1 on the owner and publish it only after workers have finished.
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

    // Worker ordering is unspecified; a bitmap detects duplicate or missing claims
    // without imposing an interleaving, while bounds checks protect its indexing.
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
    try std.testing.expectEqual(0, coordinator.publishedBatchSize(gap, count + 1));
    try std.testing.expectEqual(count, coordinator.publishedBatchSize(gap + 1, count));
    coordinator.publish(gap);
    try std.testing.expectEqual(count + 1, coordinator.publishedBatchSize(gap, count + 10));
}

test "multi-producer capacity cache does not regress under concurrent checks" {
    const producer_count = 4;
    const progress_end = 1024;
    const capacity = 8;
    const Worker = struct {
        /// Refreshes the shared capacity cache against concurrently advancing consumer progress.
        ///
        /// Each observed cursor makes its corresponding inclusive write limit safe,
        /// even if another worker has already cached a newer, larger limit.
        fn run(coordinator: *Sequencer(true), gate: *Gate, ready: *Counter, completed: *Counter) void {
            ready.increment();
            gate.wait();
            while (true) {
                const next_unread = coordinator.consumerSequence(0, .acquire) catch unreachable;
                std.debug.assert(coordinator.isSlotSafeToWrite(next_unread + capacity - 1) catch unreachable);
                if (next_unread == progress_end) break;
            }
            completed.increment();
        }
    };

    var coordinator = try Sequencer(true).init(std.testing.allocator, capacity);
    defer coordinator.deinit();
    try coordinator.initConsumers(1);
    var gate: Gate = .{};
    var ready: Counter = .{};
    var completed: Counter = .{};
    var threads: [producer_count]std.Thread = undefined;
    var started: usize = 0;
    defer {
        // On an assertion or spawn failure, let every started worker reach its exit
        // condition before joining; otherwise cleanup itself could wait forever.
        coordinator.acknowledge(0, progress_end) catch unreachable;
        gate.open();
        for (threads[0..started]) |thread| thread.join();
    }
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &coordinator, &gate, &ready, &completed });
        started += 1;
    }
    ready.waitFor(producer_count);
    gate.open();
    // The owner is the sole writer of consumer progress. Workers race to refresh the
    // cache, while the owner samples it to catch older observations moving it backward.
    var previous = cachedLimit(true, &coordinator);
    for (2..progress_end + 1) |next_unread| {
        try coordinator.acknowledge(0, next_unread);
        const current = cachedLimit(true, &coordinator);
        try std.testing.expect(current >= previous);
        previous = current;
    }
    // Every worker has checked the final cursor before signaling completion, so the
    // cache must have reached its final limit even if intermediate samples skipped updates.
    completed.waitFor(producer_count);
    try std.testing.expectEqual(progress_end + capacity - 1, cachedLimit(true, &coordinator));
}
