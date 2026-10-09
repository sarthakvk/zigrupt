// waiting_strategy.zig

const std = @import("std");

pub fn validateWaitingStrategy(comptime Strategy: type) void {
    if (!@hasDecl(Strategy, "wait"))
        @compileError("Waiting strategy must define wait(self: *Strategy) void");
    _ = @as(fn () void, Strategy.wait);
}

pub const BusySpin = struct {
    const Self = @This();

    pub fn wait() void {
        return;
    }
};
