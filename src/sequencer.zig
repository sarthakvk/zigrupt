//! Sequence claims and cached capacity checks for single- and multi-producer publishing.

const std = @import("std");

/// Cache-line-aligned sequence counter that avoids false sharing between adjacent counters.
pub const PaddedAtomicSeq = struct {
    value: std.atomic.Value(usize) align(std.atomic.cache_line),
};

/// Assigns sequences for one producer, caching capacity until consumers must be checked again.
pub const SingleProducerSequencer = struct {
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
    pub fn current(self: *Self) usize {
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
pub const MultiProducerSequencer = struct {
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
    pub fn current(self: *Self) usize {
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
