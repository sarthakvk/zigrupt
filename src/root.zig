const std = @import("std");
const disruptor = @import("disruptor.zig");
const event_bus = @import("ring_buffer.zig");

pub const Disruptor = disruptor.Disruptor;
pub const ev = event_bus.RingBufferEventBus;

pub fn hello() void {
    std.debug.print("hello, from zigrupt lib!!!\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
