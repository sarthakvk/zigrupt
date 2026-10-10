//! Fixed-capacity event storage indexed by sequence.

const std = @import("std");

/// Creates fixed-capacity storage whose sequences map to reusable slots.
///
/// Callers must synchronize shared access and finish using a slot before overwriting it.
/// Only read slots that have been initialized with `save`.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        buffer: []T,
        mask: usize,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Allocates uninitialized storage with a nonzero power-of-two `buffer_size`.
        ///
        /// Returns `IncorrectBufferSize` for invalid sizes and propagates allocation failures.
        pub fn init(allocator: std.mem.Allocator, buffer_size: usize) !Self {
            if (buffer_size == 0 or buffer_size & (buffer_size - 1) != 0) return error.IncorrectBufferSize;

            return .{
                .buffer = try allocator.alloc(T, buffer_size),
                .mask = buffer_size - 1,
                .allocator = allocator,
            };
        }

        /// Frees storage after all accesses have finished, invalidating borrowed pointers and slices.
        ///
        /// Does not release resources referenced by event values.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        /// Borrows the slot for `sequence`; its value changes when the slot is overwritten.
        pub fn get(self: *const Self, sequence: usize) *const T {
            return &self.buffer[sequence & self.mask];
        }

        /// Copies `event` into the slot for `sequence`.
        ///
        /// Pointers and slices within `event` remain caller-owned.
        pub fn save(self: *Self, sequence: usize, event: T) void {
            self.buffer[sequence & self.mask] = event;
        }

        /// Borrows up to `max_len` events without crossing the physical ring boundary.
        ///
        /// A zero `max_len` returns an empty slice.
        pub fn slice(self: *const Self, sequence: usize, max_len: usize) []const T {
            const index = sequence & self.mask;
            const len = @min(max_len, self.buffer.len - index);
            return self.buffer[index..][0..len];
        }
    };
}
