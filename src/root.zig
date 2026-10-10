//! Broadcast event bus with single- or multi-producer publishing and pluggable waiting strategies.

const std = @import("std");
const event_bus = @import("ring_buffer.zig");
/// Built-in waiting strategies and validation for custom strategies.
pub const waiting_strategy = @import("waiting_strategy.zig");

/// Creates a ring-buffer bus type; see `RingBufferEventBus` for configuration and lifecycle requirements.
pub const EventBus = event_bus.RingBufferEventBus;
/// Callback type that acknowledges a consumed prefix of an event batch.
pub const EventHandler = event_bus.EventHandler;

test {
    std.testing.refAllDecls(@This());
}
