//! Ring-buffer event bus that broadcasts events to each handler on its own consumer thread.

const std = @import("std");
const atomic = std.atomic;
const waiting_strategy = @import("waiting_strategy.zig");
const sequencer = @import("sequencer.zig");
const event_processing = @import("event_processing.zig");

const RingBuffer = @import("ring_buffer.zig").RingBuffer;

const mem = std.mem;

const EventHandler = event_processing.EventHandler;

/// Configuration and lifecycle errors returned by event bus operations.
pub const EventBusError = error{
    InvalidConfig,
    InvalidConsumerID,
    IncorrectBufferSize,
    IncorrectBatchSize,
    NoHandlersRegistered,
    BusIdle,
    BusStarting,
    BusRunning,
    BusDraining,
    BusStopped,
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
    /// final state of the bus, No consumer threads are active; the bus can not be started.
    stopped,
};

/// Creates a bus type that broadcasts each `T` event to every handler in claim order.
///
/// Set `multi_producer` for concurrent publishers; otherwise only one producer may publish.
///
/// Handlers and strategy types are fixed for the bus type; strategies expose `wait() void`.
///
/// Keep the initialized bus at a stable address while running, and do not let sequences overflow.
pub fn EventBus(
    comptime T: type,
    multi_producer: bool,
    PublisherWaitingStrategy: type,
    ConsumerWaitingStrategy: type,
) type {
    waiting_strategy.validateWaitingStrategy(PublisherWaitingStrategy);
    waiting_strategy.validateWaitingStrategy(ConsumerWaitingStrategy);

    // Sequencer type
    const Sequencer = sequencer.Sequencer(multi_producer);
    const EventProcessor = event_processing.EventProcessor(T, ConsumerWaitingStrategy);

    return struct {
        buffer: RingBuffer(T),
        max_batch_size: usize,
        state: atomic.Value(EventBusState),
        running_processes: ?[]EventProcessor,
        registered_processes: std.ArrayList(EventProcessor),

        sequencer: Sequencer,
        threads: []?std.Thread,
        lifecycle_owner: std.Thread.Id,
        allocator: mem.Allocator,

        const Self = @This();
        /// Allocates an idle bus and records the calling thread as its lifecycle owner.
        ///
        /// `buffer_size` must be a nonzero power of two (`IncorrectBufferSize` otherwise).
        ///
        /// `max_batch_size` caps callback slices and must be between one and `buffer_size`
        /// inclusive (`IncorrectBatchSize` otherwise).
        ///
        /// Allocation failures are propagated.
        pub fn init(allocator: std.mem.Allocator, buffer_size: usize, max_batch_size: usize) !Self {
            // buffer_size must be a power of 2
            if (buffer_size == 0 or buffer_size & (buffer_size - 1) != 0) return EventBusError.IncorrectBufferSize;

            if (max_batch_size == 0 or max_batch_size > buffer_size) return EventBusError.IncorrectBatchSize;

            var buffer = try RingBuffer(T).init(allocator, buffer_size);
            errdefer buffer.deinit();

            var sequence_coordinator = try Sequencer.init(allocator, buffer_size);
            errdefer sequence_coordinator.deinit();

            return .{
                .buffer = buffer,
                .max_batch_size = max_batch_size,
                .state = .init(.idle),
                .running_processes = null,
                .sequencer = sequence_coordinator,
                .threads = &.{},
                .lifecycle_owner = std.Thread.getCurrentId(),
                .allocator = allocator,
                .registered_processes = .empty,
            };
        }

        /// Register EventHandler
        pub fn registerEventHandler(self: *Self, callback: EventHandler(T)) !void {
            try self.ensureLifecycleOwner();

            switch (self.state.load(.monotonic)) {
                .draining => return EventBusError.BusDraining,
                .running => return EventBusError.BusRunning,
                .starting => return EventBusError.BusStarting,
                .stopped => return EventBusError.BusStopped,
                .idle => {},
            }

            const processor = EventProcessor.init(self.registered_processes.items.len, callback, self.max_batch_size);
            try self.registered_processes.append(self.allocator, processor);
        }

        /// Register EventHandlers
        pub fn registerEventHandlers(self: *Self, callbacks: []EventHandler(T)) !void {
            try self.ensureLifecycleOwner();

            switch (self.state.load(.monotonic)) {
                .draining => return EventBusError.BusDraining,
                .running => return EventBusError.BusRunning,
                .starting => return EventBusError.BusStarting,
                .stopped => return EventBusError.BusStopped,
                .idle => {},
            }

            for (callbacks) |callback| {
                try self.registerEventHandler(callback);
            }
        }
        /// Frees bus storage.
        ///
        /// The bus must be idle with no producer calls in flight.
        ///
        /// Does not join threads or release resources referenced by event values.
        pub fn deinit(self: *Self) void {
            self.buffer.deinit();
            self.sequencer.deinit();
            self.allocator.free(self.threads);
            self.registered_processes.deinit(self.allocator);
        }

        /// Starts one thread per handler, preserving sequence progress across restarts.
        ///
        /// Requires the initializing thread (`NotLifecycleOwner`) and an idle bus
        /// (`BusStarting`, `BusRunning`, or `BusDraining` otherwise).
        /// An empty handler list returns `NoHandlersRegistered` and leaves the bus idle.
        ///
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
                .stopped => return EventBusError.BusStopped,
                .idle => {},
            }

            if (self.registered_processes.items.len == 0) return EventBusError.NoHandlersRegistered;

            // set state to starting before doing any operations
            self.state.store(.starting, .monotonic);

            // On partial startup failure, drain and join the threads already spawned.
            errdefer self.stop() catch unreachable;

            self.running_processes = self.registered_processes.items;
            try self.sequencer.initConsumers(self.running_processes.?.len);

            self.threads = try self.allocator.alloc(?std.Thread, self.running_processes.?.len);
            @memset(self.threads, null);

            // readonly pointer to buffer
            const buffer_ro: *const RingBuffer(T) = &self.buffer;

            for (self.running_processes.?, 0..) |*proc, i| {
                self.threads[i] = try std.Thread.spawn(
                    .{ .allocator = self.allocator },
                    EventProcessor.run,
                    .{ proc, &self.state, &self.sequencer, buffer_ro },
                );
            }

            //Invariant: after start exits, the bus will be in running state.
            self.state.store(.running, .release);
        }

        /// Drains queued events, joins handler threads, and returns the bus to idle.
        ///
        /// Callers must stop production and finish all in-flight `produce()` calls before calling this.
        /// Otherwise events may be dropped: draining stops at the first unpublished claim.
        ///
        /// Handlers must make progress for this call to finish.
        ///
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
                .stopped => return EventBusError.BusStopped,
                .running => {},
                .starting => {},
            }

            self.state.store(.draining, .monotonic);
            for (self.threads) |th_op| {
                if (th_op) |th| th.join();
            }

            // Invariant: After stop exits, the bus will be in idle state.
            self.state.store(.stopped, .release);
        }

        /// Copies an event into the ring, waiting for all consumers before reusing its slot.
        ///
        /// Pointers and slices within `event` remain caller-owned and must outlive consumption.
        ///
        /// Returns `BusIdle`, `BusStarting`, or `BusDraining` if not running at entry.
        ///
        /// Once claimed, a publication waits for capacity without rechecking lifecycle state.
        pub fn produce(self: *Self, event: T) !void {
            const state = self.state.load(.monotonic);

            // Invariant: Bus will only accept events when
            // it is in running state.
            switch (state) {
                .draining => return EventBusError.BusDraining,
                .starting => return EventBusError.BusStarting,
                .idle => return EventBusError.BusIdle,
                .stopped => return EventBusError.BusStopped,
                .running => {},
            }

            const seq = self.sequencer.claim();

            // wait until the slot is safe to write
            while (!try self.sequencer.isSlotSafeToWrite(seq)) {
                PublisherWaitingStrategy.wait();
            }

            // Publish only after the event write so acquiring consumers see initialized data.
            self.buffer.save(seq, event);
            self.sequencer.publish(seq);
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
