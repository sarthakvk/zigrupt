const std = @import("std");
const event_bus = @import("ring_buffer.zig");
pub const waiting_strategy = @import("waiting_strategy.zig");

pub const EventBus = event_bus.RingBufferEventBus;
pub const EventHandler = event_bus.EventHandler;

test {
    std.testing.refAllDecls(@This());
}
