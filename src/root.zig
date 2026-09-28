const std = @import("std");
const disruptor = @import("disruptor.zig");

pub const Disruptor = disruptor.Disruptor;

pub fn hello() void {
    std.debug.print("hello, from zigrupt lib!!!\n", .{});
}
