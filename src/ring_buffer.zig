//! Fixed-capacity event broadcasting with per-handler progress and producer backpressure.
//! Sequence numbers start at one; per-slot release/acquire publication makes event writes visible.
//! Lifecycle operations belong to the initializing thread; producers must finish before stopping.

const std = @import("std");
const atomic = std.atomic;
const waiting_strategy = @import("waiting_strategy.zig");

const mem = std.mem;

/// Cache-line-aligned sequence counter that avoids false sharing between adjacent counters.
const PaddedAtomicSeq = struct {
    value: std.atomic.Value(usize) align(std.atomic.cache_line),
};

/// Callback that returns the number of events consumed from the start of a batch.
/// Return at most the slice length; zero retries the same events without advancing progress.
/// The slice is borrowed for the call only. Each handler runs on its own consumer thread.
pub fn EventHandler(comptime T: type) type {
    return *const fn ([]const T) usize;
}

/// Configuration and lifecycle errors returned by event bus operations.
pub const EventBusError = error{
    InvalidConfig,
    InvalidConsumerID,
    IncorrectBufferSize,
    IncorrectBatchSize,
    BusIdle,
    BusStarting,
    BusRunning,
    BusDraining,
    NotLifecycleOwner,
};

/// Lifecycle phases controlling whether events may be published or consumed.
pub const EventBusState = enum(u8) {
    /// No consumer threads are active; the bus may be started.
    idle,
    /// Consumer threads are being spawned and wait for startup to finish.
    starting,
    /// Publishers may submit events and consumers process them.
    running,
    /// New publications are rejected while consumers finish queued events.
    draining,
};

/// Assigns sequences for one producer, caching capacity until consumers must be checked again.
const SingleProducerSequencer = struct {
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

    /// Reserves the next sequence; only the sole producer may call this, and it does not publish.
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
const MultiProducerSequencer = struct {
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

/// Creates a bus type that broadcasts each `T` event to every handler in claim order.
/// Set `multi_producer` for concurrent publishers; otherwise only one producer may publish.
/// Handlers and strategy types are fixed for the bus type; strategies expose `wait() void`.
/// Keep the initialized bus at a stable address while running, and do not let sequences overflow.
pub fn RingBufferEventBus(
    comptime T: type,
    multi_producer: bool,
    event_handlers: []const EventHandler(T),
    PublisherWaitingStrategy: type,
    ConsumerWaitingStrategy: type,
) type {
    waiting_strategy.validateWaitingStrategy(PublisherWaitingStrategy);
    waiting_strategy.validateWaitingStrategy(ConsumerWaitingStrategy);

    const Sequencer = if (multi_producer) MultiProducerSequencer else SingleProducerSequencer;

    return struct {
        buffer: []T,
        buffer_seq: []atomic.Value(usize),
        max_batch_size: usize,
        consumer_seq: []PaddedAtomicSeq,
        mask: usize,
        state: atomic.Value(EventBusState),

        sequencer: Sequencer,
        threads: []?std.Thread,
        lifecycle_owner: std.Thread.Id,
        allocator: mem.Allocator,

        const Self = @This();
        /// Allocates an idle bus and records the calling thread as its lifecycle owner.
        /// `buffer_size` must be a nonzero power of two (`IncorrectBufferSize` otherwise).
        /// `max_batch_size` caps callback slices and must be between one and `buffer_size`
        /// inclusive (`IncorrectBatchSize` otherwise). Allocation failures are propagated.
        pub fn init(allocator: std.mem.Allocator, buffer_size: usize, max_batch_size: usize) !Self {
            // buffer_size must be a power of 2
            if (buffer_size == 0 or buffer_size & (buffer_size - 1) != 0) return EventBusError.IncorrectBufferSize;

            if (max_batch_size == 0 or max_batch_size > buffer_size) return EventBusError.IncorrectBatchSize;

            const buffer = try allocator.alloc(T, buffer_size);
            errdefer allocator.free(buffer);

            const buffer_seq = try allocator.alloc(atomic.Value(usize), buffer_size);
            errdefer allocator.free(buffer_seq);
            @memset(buffer_seq, .init(0));

            const consumer_seq = try allocator.alloc(PaddedAtomicSeq, event_handlers.len);
            errdefer allocator.free(consumer_seq);
            @memset(consumer_seq, .{ .value = .init(1) });

            const threads = try allocator.alloc(?std.Thread, event_handlers.len);
            errdefer allocator.free(threads);
            @memset(threads, null);

            return .{
                .buffer = buffer,
                .buffer_seq = buffer_seq,
                .max_batch_size = max_batch_size,
                .consumer_seq = consumer_seq,
                .mask = (buffer_size - 1),
                .state = .init(.idle),
                .sequencer = Sequencer.init(buffer_size),
                .threads = threads,
                .lifecycle_owner = std.Thread.getCurrentId(),
                .allocator = allocator,
            };
        }

        /// Frees bus storage; the bus must be idle with no producer calls in flight.
        /// Does not join threads or release resources referenced by event values.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.allocator.free(self.buffer_seq);
            self.allocator.free(self.consumer_seq);
            self.allocator.free(self.threads);
        }

        /// Starts one thread per handler, preserving sequence progress across restarts.
        /// Requires the initializing thread (`NotLifecycleOwner`) and an idle bus
        /// (`BusStarting`, `BusRunning`, or `BusDraining` otherwise).
        /// Thread-spawn errors are propagated after joining any threads already started.
        pub fn start(self: *Self) !void {
            try self.ensureLifecycleOwner();

            const state = self.state.load(.acquire);

            // Invariant: start can only be called when the bus is
            // idle.
            switch (state) {
                .draining => return EventBusError.BusDraining,
                .running => return EventBusError.BusRunning,
                .starting => return EventBusError.BusStarting,
                .idle => {},
            }

            self.state.store(.starting, .monotonic);

            // On partial startup failure, drain and join the threads already spawned.
            errdefer self.stop() catch unreachable;

            for (0..event_handlers.len) |eid| {
                self.threads[eid] = try std.Thread.spawn(
                    .{ .allocator = self.allocator },
                    Self.handleEvent,
                    .{ self, eid },
                );
            }

            //Invariant: after start exits, the bus will be in running state.
            self.state.store(.running, .release);
        }

        /// Drains queued events, joins handler threads, and returns the bus to idle.
        /// Finish and join producers first: draining stops at an unpublished claim.
        /// Handlers must make progress for this call to finish.
        /// Requires the initializing thread (`NotLifecycleOwner`); returns `BusIdle`
        /// or `BusDraining` when already in that state.
        pub fn stop(self: *Self) !void {
            try self.ensureLifecycleOwner();

            const state = self.state.load(.monotonic);

            // Invariant: stop can only be called when the bus is
            // either running or starting.
            switch (state) {
                .draining => return EventBusError.BusDraining,
                .idle => return EventBusError.BusIdle,
                .running => {},
                .starting => {},
            }

            self.state.store(.draining, .monotonic);

            for (self.threads) |th_| if (th_) |th| th.join();
            @memset(self.threads, null);

            // Invariant: After stop exits, the bus will be in idle state.
            self.state.store(.idle, .release);
        }

        /// Runs one handler over contiguous published batches without crossing the ring boundary.
        /// `handler_id` selects its callback and progress counter; only this thread advances it.
        /// Acquire publication loads expose event data; release progress stores permit slot reuse.
        fn handleEvent(self: *Self, handler_id: usize) void {
            const handler = event_handlers[handler_id];
            var c_seq = self.consumer_seq[handler_id].value.load(.monotonic);

            var state = self.state.load(.monotonic);

            // Invariant: Events are only consumed when the bus is in running/draining state.
            while (state == .starting) : (state = self.state.load(.monotonic)) ConsumerWaitingStrategy.wait();

            while (state == .running) : (state = self.state.load(.monotonic)) {
                const buffer_seq = self.buffer_seq[(c_seq & self.mask)].load(.acquire);

                if (buffer_seq == 0 or c_seq > buffer_seq) {
                    ConsumerWaitingStrategy.wait();
                    continue;
                }
                const index = c_seq & self.mask;
                const limit = @min(self.max_batch_size, self.buffer.len - index);
                var batch_size: usize = 1;

                while (batch_size < limit) : (batch_size += 1) {
                    const expected = c_seq + batch_size;
                    const published = self.buffer_seq[index + batch_size].load(.acquire);
                    if (published != expected) break;
                }

                const events_slice = self.buffer[index..][0..batch_size];
                c_seq += handler(events_slice);
                self.consumer_seq[handler_id].value.store(c_seq, .release);
            }

            // Invariant: after running, the state can only be draining
            // until all the handler threads join.
            std.debug.assert(state == .draining);

            // Snapshot claims for draining; an unpublished gap ends the drain below.
            const cursor = self.sequencer.current();

            while (c_seq < cursor) {
                const buffer_seq = self.buffer_seq[(c_seq & self.mask)].load(.acquire);

                if (buffer_seq == 0 or c_seq > buffer_seq) break;

                const index = c_seq & self.mask;
                const limit = @min(self.max_batch_size, self.buffer.len - index, cursor - c_seq);
                var batch_size: usize = 1;

                while (batch_size < limit) : (batch_size += 1) {
                    const expected = c_seq + batch_size;
                    const published = self.buffer_seq[index + batch_size].load(.acquire);
                    if (published != expected) break;
                }

                const events_slice = self.buffer[index..][0..batch_size];

                c_seq += handler(events_slice);
                self.consumer_seq[handler_id].value.store(c_seq, .release);
            }
        }

        /// Copies an event into the ring, waiting for all consumers before reusing its slot.
        /// Pointers and slices within `event` remain caller-owned and must outlive consumption.
        /// Returns `BusIdle`, `BusStarting`, or `BusDraining` if not running at entry.
        /// Once claimed, a publication waits for capacity without rechecking lifecycle state.
        pub fn produce(self: *Self, event: T) !void {
            const state = self.state.load(.monotonic);

            // Invariant: Bus will only accept events when
            // it is in running state.
            switch (state) {
                .draining => return EventBusError.BusDraining,
                .starting => return EventBusError.BusStarting,
                .idle => return EventBusError.BusIdle,
                .running => {},
            }

            const seq = self.sequencer.claim();

            // wait until the slot is safe to write
            while (!self.sequencer.isSlotSafeToWrite(seq, self.consumer_seq)) {
                PublisherWaitingStrategy.wait();
            }

            // Publish only after the event write so acquiring consumers see initialized data.
            const seq_idx = seq & self.mask;
            self.buffer[seq_idx] = event;
            self.buffer_seq[seq_idx].store(seq, .release);
        }

        /// Returns `NotLifecycleOwner` when called outside the initializing thread.
        fn ensureLifecycleOwner(self: *Self) !void {
            if (!self.isLifecycleOwner()) return EventBusError.NotLifecycleOwner;
        }

        /// Checks whether the caller is the thread that initialized this bus.
        fn isLifecycleOwner(self: *Self) bool {
            return self.lifecycle_owner == std.Thread.getCurrentId();
        }
    };
}
