const std = @import("std");
const atomic = std.atomic;

const validateWaitingStrategy = @import("waiting_strategy.zig").validateWaitingStrategy;
const EventBusState = @import("event_bus.zig").EventBusState;

/// Callback that returns the number of events consumed from the start of a batch.
///
/// Return at most the slice length; zero retries the same events without advancing progress.
///
/// The slice is borrowed for the call only.
///
/// Each handler runs on its own consumer thread.
pub fn EventHandler(comptime T: type) type {
    return *const fn ([]const T) usize;
}

pub fn EventProcessor(
    comptime Event: type,
    comptime WaitingStrategy: type,
) type {
    validateWaitingStrategy(WaitingStrategy);
    return struct {
        id: usize,
        callback: EventHandler(Event),
        max_batch_size: usize,

        const Self = @This();

        pub fn init(id: usize, callback: EventHandler(Event), max_batch_size: usize) Self {
            return .{ .id = id, .callback = callback, .max_batch_size = max_batch_size };
        }

        /// Runs handler over contiguous published batches without crossing the ring boundary.
        ///
        /// Acquire publication loads expose event data; release progress stores permit slot reuse.
        pub fn run(self: *Self, bus_state: *const atomic.Value(EventBusState), sequencer: anytype, storage: anytype) !void {
            var c_seq = try sequencer.consumerSequence(self.id, .monotonic);

            var state = bus_state.load(.monotonic);

            // Invariant: Events are only consumed when the bus is in running/draining state.
            while (state == .starting) : (state = bus_state.load(.monotonic)) WaitingStrategy.wait();

            while (state == .running) : (state = bus_state.load(.monotonic)) {
                const batch_size = sequencer.publishedBatchSize(c_seq, self.max_batch_size);
                if (batch_size == 0) {
                    WaitingStrategy.wait();
                    continue;
                }

                const events_slice = storage.slice(c_seq, batch_size);
                c_seq += self.callback(events_slice);
                try sequencer.acknowledge(self.id, c_seq);
            }

            // Invariant: after running, the state can only be draining
            // until all the handler threads join.
            std.debug.assert(state == .draining);

            // Snapshot claims for draining; an unpublished gap ends the drain below.
            const cursor = sequencer.nextClaimSequence();

            while (c_seq < cursor) {
                const batch_size = sequencer.publishedBatchSize(c_seq, self.max_batch_size);
                if (batch_size == 0) break;

                const events_slice = storage.slice(c_seq, batch_size);
                c_seq += self.callback(events_slice);
                try sequencer.acknowledge(self.id, c_seq);
            }
        }
    };
}
