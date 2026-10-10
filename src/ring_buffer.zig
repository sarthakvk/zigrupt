//
// ring_buffer.zig
//

const std = @import("std");
const atomic = std.atomic;
const waiting_strategy = @import("waiting_strategy.zig");

const mem = std.mem;

const PaddedAtomicSeq = struct {
    value: std.atomic.Value(usize) align(std.atomic.cache_line),
};

/// EventHandler
/// Event handlers is a function that accepts a slice of events to process
/// and returns the number of events consumed.
/// The returned values must be <= input slice length
pub fn EventHandler(comptime T: type) type {
    return *const fn ([]const T) usize;
}

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

pub const EventBusState = enum(u8) {
    idle,
    starting,
    running,
    draining,
};

const SingleProducerSequencer = struct {
    next: PaddedAtomicSeq,
    safe_to_write_through: usize align(std.atomic.cache_line),
    buffer_size: usize,

    const Self = @This();

    pub fn init(buffer_size: usize) Self {
        return .{
            .next = .{ .value = .init(1) },
            .safe_to_write_through = buffer_size,
            .buffer_size = buffer_size,
        };
    }

    pub fn claim(self: *Self) usize {
        const seq = self.next.value.load(.monotonic);
        self.next.value.store(seq + 1, .release);
        return seq;
    }

    pub fn current(self: *Self) usize {
        return self.next.value.load(.acquire);
    }

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

const MultiProducerSequencer = struct {
    next: PaddedAtomicSeq,
    safe_to_write_through: PaddedAtomicSeq,
    buffer_size: usize,

    const Self = @This();

    pub fn init(buffer_size: usize) Self {
        return .{
            .next = PaddedAtomicSeq{ .value = .init(1) },
            .safe_to_write_through = PaddedAtomicSeq{ .value = .init(buffer_size) },
            .buffer_size = buffer_size,
        };
    }

    pub fn claim(self: *Self) usize {
        return self.next.value.fetchAdd(1, .monotonic);
    }

    pub fn current(self: *Self) usize {
        return self.next.value.load(.acquire);
    }

    pub fn isSlotSafeToWrite(self: *Self, seq: usize, consumer_seq: []PaddedAtomicSeq) bool {
        var cur = self.safe_to_write_through.value.load(.acquire);
        if (seq <= cur) return true;

        var slowest_consumer_seq: usize = std.math.maxInt(usize);

        for (consumer_seq) |*cseq| {
            slowest_consumer_seq = @min(slowest_consumer_seq, cseq.value.load(.acquire));
        }

        const candidate = slowest_consumer_seq +| (self.buffer_size - 1);

        if (cur >= candidate) return seq <= candidate;

        // Do a compare and swap
        // If the value changed concurrently, then keep the max one
        while (cur < candidate) {
            if (self.safe_to_write_through.value.cmpxchgWeak(cur, candidate, .acq_rel, .acquire)) |updated| {
                // CAS failed
                // try again after updated cur to the latest value.
                cur = updated;
            } else {
                // CAS succeeded
                // candidate is the greatest safe_to_write_through
                // so we compare with candidate.
                return seq <= candidate;
            }
        }

        // If we reach here, that means
        // another producer updated the safe_to_write_through to cur
        // and it is greater than what we calculated, so we compare with cur.
        return seq <= cur;
    }
};

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
        /// Initialize the RingBuffer
        /// Args:
        ///     - allocator: Allocator interface
        ///     - buffer_size: size of ring buffer, must be a power of 2
        ///     - max_batch_size: Maximum length of events slice sent to event_handler
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

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.allocator.free(self.buffer_seq);
            self.allocator.free(self.consumer_seq);
            self.allocator.free(self.threads);
        }

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

            // this handles partial failures, the threads that were started
            // will receive the signal to stop.
            // when the stop will be called here, the state can only be
            // idle/running
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

        // Stop the Bus
        // This method will put the bus into `draining` state and wait for the
        // even handlers to finish consuming published events.
        //
        // It takes no gurantee for in-flight events, they might be dropped It is callers
        // responsiblity to make sure the production has stopped before calling stop.
        //
        // Once the stop returns the bus will be in `idle` state and can be started again.
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

            // Cursor will always be the next available sequence
            // once the event handlers reach cursor, they've consumed
            // all the in-flight/queued events
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

            // Finally store release the event
            const seq_idx = seq & self.mask;
            self.buffer[seq_idx] = event;
            self.buffer_seq[seq_idx].store(seq, .release);
        }

        fn ensureLifecycleOwner(self: *Self) !void {
            if (!self.isLifecycleOwner()) return EventBusError.NotLifecycleOwner;
        }

        fn isLifecycleOwner(self: *Self) bool {
            return self.lifecycle_owner == std.Thread.getCurrentId();
        }
    };
}
