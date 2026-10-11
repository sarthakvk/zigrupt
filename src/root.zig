//! Public API for the event bus and waiting strategies.

const std = @import("std");
const event_bus = @import("event_bus.zig");

/// Creates a ring-buffer bus type; see `EventBus` in `event_bus.zig` for configuration and lifecycle requirements.
pub const EventBus = event_bus.EventBus;

/// Callback type that acknowledges a consumed prefix of an event batch.
pub const EventHandler = event_bus.EventHandler;

/// Fixed-capacity event storage indexed by sequence.
pub const RingBuffer = @import("ring_buffer.zig").RingBuffer;

/// Built-in waiting strategies and validation for custom strategies.
pub const waiting_strategy = @import("waiting_strategy.zig");

test {
    std.testing.refAllDecls(@This());
}
