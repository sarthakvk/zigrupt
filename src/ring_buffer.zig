//
// ring_buffer.zig
//

const std = @import("std");
const atomic = std.atomic;
const waiting_strategy = @import("waiting_strategy.zig");

const mem = std.mem;

const PaddedSeq = struct {
    value: std.atomic.Value(usize) align(std.atomic.cache_line),
};

pub const EventBusError = error{
    InvalidConfig,
    InvalidConsumerID,
    IncorrectBufferSize,
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

pub fn RingBufferEventBus(
    comptime T: type,
    multi_producer: bool,
    event_handlers: []const *const fn (T) void,
    PublisherWaitingStrategy: type,
    ConsumerWaitingStrategy: type,
) type {
    waiting_strategy.validateWaitingStrategy(PublisherWaitingStrategy);
    waiting_strategy.validateWaitingStrategy(ConsumerWaitingStrategy);

    return struct {
        buffer: []T,
        buffer_seq: []atomic.Value(usize),
        cursor: *PaddedSeq,
        consumer_seq: []PaddedSeq,
        mask: usize,
        state: atomic.Value(EventBusState),

        threads: []?std.Thread,
        lifecycle_owner: std.Thread.Id,
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

            const threads = try allocator.alloc(?std.Thread, event_handlers.len);
            errdefer allocator.free(threads);
            @memset(threads, null);

            return .{
                .buffer = buffer,
                .buffer_seq = buffer_seq,
                .cursor = cursor,
                .consumer_seq = consumer_seq,
                .mask = (buffer_size - 1),
                .state = .init(.idle),
                .threads = threads,
                .lifecycle_owner = std.Thread.getCurrentId(),
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

                const event = self.buffer[(c_seq & self.mask)];

                handler(event);

                c_seq += 1;
                self.consumer_seq[handler_id].value.store(c_seq, .release);
            }

            // Invariant: after running, the state can only be draining
            // until all the handler threads join.
            std.debug.assert(state == .draining);

            // Cursor will always be the next available sequence
            // once the event handlers reach cursor, they've consumed
            // all the in-flight/queued events
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
            const state = self.state.load(.monotonic);

            // Invariant: Bus will only accept events when
            // it is in running state.
            switch (state) {
                .draining => return EventBusError.BusDraining,
                .starting => return EventBusError.BusStarting,
                .idle => return EventBusError.BusIdle,
                .running => {},
            }

            // select producer strategy, this will be done at comptime, as the multi_producer is a comptime argument.
            const produce_fn = if (multi_producer) Self.multi_producer_produce else Self.single_producer_produce;
            try produce_fn(self, event);
        }

        fn ensureLifecycleOwner(self: *Self) !void {
            if (!self.isLifecycleOwner()) return EventBusError.NotLifecycleOwner;
        }

        fn isLifecycleOwner(self: *Self) bool {
            return self.lifecycle_owner == std.Thread.getCurrentId();
        }

        fn multi_producer_produce(self: *Self, event: T) !void {
            var seq = self.cursor.value.raw;

            // claim a seq using CAS
            while (self.cursor.value.cmpxchgWeak(seq, seq + 1, .monotonic, .monotonic)) |new_seq| {
                seq = new_seq;
            }

            // wait until the slot is safe to write
            while (!self.isSlotSafeToWrite(seq)) {
                PublisherWaitingStrategy.wait();
            }

            // Finally store release the event
            const seq_idx = seq & self.mask;
            self.buffer[seq_idx] = event;
            self.buffer_seq[seq_idx].store(seq, .release);
        }

        fn single_producer_produce(self: *Self, event: T) !void {
            const claimed_seq = self.cursor.value.fetchAdd(1, .monotonic);
            const buffer_idx = (claimed_seq & self.mask);
            while (!self.isSlotSafeToWrite(claimed_seq)) PublisherWaitingStrategy.wait();

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
