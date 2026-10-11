//! Blocking gates and counters for coordinating test threads without timing assumptions.

const std = @import("std");
const io = std.testing.io;

/// One-shot test gate backed by a mutex and condition variable.
///
/// Starts closed; opening it releases all current and future waiters. Writes preceding
/// the first `open()` are visible after `wait()` returns, allowing non-atomic setup handoff.
///
/// Keep the gate at a stable address until all threads using it have joined.
pub const Gate = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    opened: bool = false,

    /// Blocks without cancellation until the gate opens; returns immediately if already open.
    pub fn wait(self: *Gate) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        // A wakeup is not itself permission to proceed; recheck the protected predicate.
        while (!self.opened) self.condition.waitUncancelable(io, &self.mutex);
    }

    /// Permanently opens the gate and wakes all waiters. Repeated calls are safe.
    pub fn open(self: *Gate) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.opened = true;
        self.condition.broadcast(io);
    }
};

/// Thread-safe test counter backed by a mutex and condition variable.
///
/// Starts at zero and lets threads wait for a minimum number of recorded events.
/// Each test defines what an increment means: arrival, callback entry, or completion.
///
/// `get()` is a snapshot, not a barrier against subsequent increments. Hold workers
/// behind a separate gate when an assertion requires their progress to stay fixed.
pub const Counter = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    value: usize = 0,

    /// Increments the counter under its mutex and wakes all waiters to recheck their targets.
    pub fn increment(self: *Counter) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.value += 1;
        self.condition.broadcast(io);
    }

    /// Returns a mutex-protected snapshot of the counter's current value.
    pub fn get(self: *Counter) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.value;
    }

    /// Blocks without cancellation until the counter reaches or exceeds the target.
    pub fn waitFor(self: *Counter, target: usize) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.value < target) self.condition.waitUncancelable(io, &self.mutex);
    }
};
