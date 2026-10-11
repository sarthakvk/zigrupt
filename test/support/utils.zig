//! Event recording and drain synchronization shared by event-bus tests.
//!
//! Recorders are handler-owned while a bus runs. Tests configure them before startup
//! and inspect their non-atomic output after stop has joined the handler threads.

const std = @import("std");
const Gate = @import("synchronization.zig").Gate;
const Counter = @import("synchronization.zig").Counter;

/// Creates an isolated single-event recorder for `id`, storing up to `event_count` values.
///
/// Distinct IDs give handlers separate recording state even when their capacities match.
/// Only its handler writes recorded values; reset before starting and inspect after joining.
///
/// Setting `entered` and `gate` holds the first callback before it acknowledges anything,
/// keeping that handler's next-unread sequence at one on a fresh bus.
pub fn Recorder(comptime id: usize, comptime event_count: usize) type {
    return struct {
        pub var values: [event_count]usize = undefined;
        pub var count: usize = 0;
        // Optional first-event pause; both controls are configured before the handler starts.
        pub var gate: ?*Gate = null;
        pub var entered: ?*Counter = null;
        var unique_id = id;

        /// Clears progress and optional pause controls.
        ///
        /// No handler calls may be in flight.
        pub fn reset() void {
            count = 0;
            gate = null;
            entered = null;
        }

        /// Records one event, optionally signaling `entered` and waiting on `gate` on its first call.
        ///
        /// Requires a one-event batch and a non-null gate whenever `entered` is set.
        pub fn handle(events: []const usize) usize {
            std.debug.assert(events.len == 1);
            const value = events[0];
            // Paused-handler tests stop at the first event, before the bus can
            // advance this consumer's sequence. Signal once per handler, not
            // per event, so `entered` counts handlers that reached the gate.
            if (count == 0) {
                if (entered) |signal| {
                    signal.increment();
                    gate.?.wait();
                }
            }
            // Count excess deliveries so assertions fail without overrunning storage.
            if (count < values.len) values[count] = value;
            count += 1;
            return 1;
        }

        /// Asserts exactly `len` deliveries with consecutive values beginning at `start`.
        pub fn expectRange(start: usize, len: usize) !void {
            try std.testing.expectEqual(len, count);
            for (values[0..len], start..) |value, expected| {
                try std.testing.expectEqual(expected, value);
            }
        }
    };
}

/// Opens the handlers' gate only after draining begins, forcing queued events through `stop()`.
///
/// Run on a separate thread while the lifecycle owner stops the bus. Calling this on
/// the owner would prevent `stop()` from ever setting the state it waits for.
///
/// Producers must already be finished, and at least one handler must still be held by
/// the gate so the bus cannot finish draining before this thread observes the state.
pub fn releaseWhenDraining(bus: anytype, gate: *Gate) void {
    while (bus.state.load(.acquire) != .draining) std.Thread.yield() catch {};
    gate.open();
}
