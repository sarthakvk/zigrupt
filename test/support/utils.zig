//! Event recording and drain synchronization shared by ring-buffer tests.

const std = @import("std");
const Gate = @import("synchronization.zig").Gate;
const Counter = @import("synchronization.zig").Counter;

/// Creates an isolated single-event recorder for `id`, storing up to `event_count` values.
/// Only its handler writes recorded values; reset before starting and inspect after joining.
pub fn Recorder(comptime id: usize, comptime event_count: usize) type {
    return struct {
        pub var values: [event_count]usize = undefined;
        pub var count: usize = 0;
        pub var gate: ?*Gate = null;
        pub var entered: ?*Counter = null;
        var unique_id = id;

        /// Clears progress and optional pause controls; no handler calls may be in flight.
        pub fn reset() void {
            count = 0;
            gate = null;
            entered = null;
        }

        /// Records one event, optionally signaling `entered` and waiting on `gate` on its first call.
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
/// Run on a separate thread while the lifecycle owner stops the bus.
pub fn releaseWhenDraining(bus: anytype, gate: *Gate) void {
    while (bus.state.load(.acquire) != .draining) std.Thread.yield() catch {};
    gate.open();
}
