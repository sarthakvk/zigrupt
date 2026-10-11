//! Sequence claims, publication tracking, consumer progress, and ring-buffer slot reuse.

const std = @import("std");

/// Cache-line-aligned sequence counter that avoids false sharing between adjacent counters.
const PaddedAtomicSeq = struct {
    value: std.atomic.Value(usize) align(std.atomic.cache_line),
};

/// Owns sequence coordination independently of event storage, waiting, and lifecycle.
///
/// Sequences start at one and must not overflow. Consumers track their next unread sequence.
pub fn Sequencer(comptime multi_producer: bool) type {
    const ClaimPolicy = if (multi_producer) MultipleClaimPolicy else SingleClaimPolicy;

    return struct {
        claim_policy: ClaimPolicy,
        buffer_seq: []std.atomic.Value(usize),
        consumer_seq: []PaddedAtomicSeq,
        mask: usize,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Allocates unpublished slot markers and consumer counters starting at one.
        pub fn init(allocator: std.mem.Allocator, buffer_size: usize, consumer_count: usize) !Self {
            if (buffer_size == 0 or buffer_size & (buffer_size - 1) != 0) return error.IncorrectBufferSize;

            const buffer_seq = try allocator.alloc(std.atomic.Value(usize), buffer_size);
            errdefer allocator.free(buffer_seq);
            @memset(buffer_seq, .init(0));

            const consumer_seq = try allocator.alloc(PaddedAtomicSeq, consumer_count);
            errdefer allocator.free(consumer_seq);
            @memset(consumer_seq, .{ .value = .init(1) });

            return .{
                .claim_policy = ClaimPolicy.init(buffer_size),
                .buffer_seq = buffer_seq,
                .consumer_seq = consumer_seq,
                .mask = buffer_size - 1,
                .allocator = allocator,
            };
        }

        /// Frees coordination storage after all producers and consumers have finished.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer_seq);
            self.allocator.free(self.consumer_seq);
        }

        /// Reserves a sequence without waiting for capacity or publishing it.
        pub fn claim(self: *Self) usize {
            return self.claim_policy.claim();
        }

        /// Returns claim progress, which may be ahead of contiguous publication progress.
        pub fn nextClaimSequence(self: *const Self) usize {
            return self.claim_policy.nextClaimSequence();
        }

        /// Checks slot reuse against this sequencer's consumer counters.
        pub fn isSlotSafeToWrite(self: *Self, sequence: usize) bool {
            return self.claim_policy.isSlotSafeToWrite(sequence, self.consumer_seq);
        }

        /// Release-publishes a slot after the caller has written its event.
        pub fn publish(self: *Self, sequence: usize) void {
            self.buffer_seq[sequence & self.mask].store(sequence, .release);
        }

        /// Acquire-checks a contiguous published prefix without crossing the physical ring boundary.
        ///
        /// Stops at any missing or stale marker, `max_count`, or the optional exclusive end.
        pub fn publishedBatchSize(self: *const Self, first: usize, max_count: usize, end_exclusive: ?usize) usize {
            if (first == 0) return 0;
            const index = first & self.mask;
            var limit = @min(max_count, self.buffer_seq.len - index);
            if (end_exclusive) |end| {
                if (end <= first) return 0;
                limit = @min(limit, end - first);
            }

            var count: usize = 0;
            while (count < limit) : (count += 1) {
                if (self.buffer_seq[index + count].load(.acquire) != first + count) break;
            }
            return count;
        }

        /// Reads next-unread progress with acquire ordering for cross-thread observations.
        ///
        /// The owning consumer may use monotonic ordering when loading its startup cursor.
        pub fn consumerSequence(self: *const Self, consumer_id: usize, comptime ordering: std.builtin.AtomicOrder) usize {
            comptime std.debug.assert(ordering == .monotonic or ordering == .acquire);
            return self.consumer_seq[consumer_id].value.load(ordering);
        }

        /// Release-acknowledges a consumed prefix; only this consumer advances its counter.
        pub fn acknowledge(self: *Self, consumer_id: usize, next_unread: usize) void {
            self.consumer_seq[consumer_id].value.store(next_unread, .release);
        }
    };
}

/// Assigns sequences for one producer, caching capacity until consumers must be checked again.
const SingleClaimPolicy = struct {
    next: PaddedAtomicSeq,
    safe_to_write_through: usize align(std.atomic.cache_line),
    buffer_size: usize,

    const Self = @This();

    /// Starts claims at sequence one with `buffer_size` initially writable slots.
    pub fn init(buffer_size: usize) Self {
        return .{
            .next = .{ .value = .init(1) },
            .safe_to_write_through = buffer_size,
            .buffer_size = buffer_size,
        };
    }

    /// Reserves the next sequence without publishing it.
    ///
    /// Only the sole producer may call this.
    pub fn claim(self: *Self) usize {
        const seq = self.next.value.load(.monotonic);
        self.next.value.store(seq + 1, .release);
        return seq;
    }

    /// Returns the next unclaimed sequence, not necessarily the end of published events.
    pub fn nextClaimSequence(self: *const Self) usize {
        return self.next.value.load(.acquire);
    }

    /// Checks whether reusing `seq`'s slot preserves every consumer's unread events.
    ///
    /// Consumer counters name their next unread sequence; no consumers means no backpressure.
    pub fn isSlotSafeToWrite(self: *Self, seq: usize, consumer_seq: []PaddedAtomicSeq) bool {
        if (seq <= self.safe_to_write_through) return true;

        var slowest_consumer_seq: usize = std.math.maxInt(usize);

        for (consumer_seq) |*cseq| {
            slowest_consumer_seq = @min(slowest_consumer_seq, cseq.value.load(.acquire));
        }
        self.safe_to_write_through = slowest_consumer_seq +| (self.buffer_size - 1);

        return seq <= self.safe_to_write_through;
    }
};

/// Atomically assigns unique sequences and shares a cached capacity limit between producers.
const MultipleClaimPolicy = struct {
    next: PaddedAtomicSeq,
    safe_to_write_through: PaddedAtomicSeq,
    buffer_size: usize,

    const Self = @This();

    /// Starts claims at sequence one with `buffer_size` initially writable slots.
    pub fn init(buffer_size: usize) Self {
        return .{
            .next = PaddedAtomicSeq{ .value = .init(1) },
            .safe_to_write_through = PaddedAtomicSeq{ .value = .init(buffer_size) },
            .buffer_size = buffer_size,
        };
    }

    /// Atomically reserves a unique sequence without waiting for capacity or publishing it.
    pub fn claim(self: *Self) usize {
        return self.next.value.fetchAdd(1, .monotonic);
    }

    /// Returns the next unclaimed sequence; earlier claims may still be unpublished.
    pub fn nextClaimSequence(self: *const Self) usize {
        return self.next.value.load(.acquire);
    }

    /// Checks slot reuse against the slowest consumer and atomically advances the cached limit.
    ///
    /// Consumer counters name their next unread sequence; no consumers means no backpressure.
    pub fn isSlotSafeToWrite(self: *Self, seq: usize, consumer_seq: []PaddedAtomicSeq) bool {
        var cur = self.safe_to_write_through.value.load(.acquire);
        if (seq <= cur) return true;

        var slowest_consumer_seq: usize = std.math.maxInt(usize);

        for (consumer_seq) |*cseq| {
            slowest_consumer_seq = @min(slowest_consumer_seq, cseq.value.load(.acquire));
        }

        const candidate = slowest_consumer_seq +| (self.buffer_size - 1);

        if (cur >= candidate) return seq <= candidate;

        // Never move the shared limit backward if another producer observed newer progress.
        while (cur < candidate) {
            if (self.safe_to_write_through.value.cmpxchgWeak(cur, candidate, .acq_rel, .acquire)) |updated| {
                cur = updated;
            } else {
                return seq <= candidate;
            }
        }

        return seq <= cur;
    }
};
