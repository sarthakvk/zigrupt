const std = @import("std");
const Gate = @import("synchronization.zig").Gate;
const Counter = @import("synchronization.zig").Counter;

/// Each id gives a handler its own recording state within a test executable.
/// Only that handler writes it; tests read values after stop() joins the handlers.
pub fn Recorder(comptime id: usize, comptime event_count: usize) type {
    return struct {
        pub var values: [event_count]usize = undefined;
        pub var count: usize = 0;
        pub var gate: ?*Gate = null;
        pub var entered: ?*Counter = null;
        var unique_id = id;

        pub fn reset() void {
            count = 0;
            gate = null;
            entered = null;
        }

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

        pub fn expectRange(start: usize, len: usize) !void {
            try std.testing.expectEqual(len, count);
            for (values[0..len], start..) |value, expected| {
                try std.testing.expectEqual(expected, value);
            }
        }
    };
}

// stop() blocks on the paused handlers, so another thread releases them only
// after draining begins. This ensures stop(), not normal consumption, drains the queue.
pub fn releaseWhenDraining(bus: anytype, gate: *Gate) void {
    while (bus.state.load(.acquire) != .draining) std.Thread.yield() catch {};
    gate.open();
}
