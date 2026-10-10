//! Waiting strategies for event publishers and consumers.

const std = @import("std");

/// Rejects strategies without a `wait` declaration of type `fn () void` at compile time.
pub fn validateWaitingStrategy(comptime Strategy: type) void {
    if (!@hasDecl(Strategy, "wait"))
        @compileError("Waiting strategy must define wait(self: *Strategy) void");
    _ = @as(fn () void, Strategy.wait);
}

/// Retries immediately without sleeping or yielding, trading CPU usage for low latency.
pub const BusySpin = struct {
    const Self = @This();

    /// Returns immediately so the caller can retry its condition.
    pub fn wait() void {
        return;
    }
};
