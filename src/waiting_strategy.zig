//! Waiting strategies used when publishers lack capacity or consumers lack published events.
//!
//! Custom strategies must expose a zero-argument `wait() void` callable from multiple threads.

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
