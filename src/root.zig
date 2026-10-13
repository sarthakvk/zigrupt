//! Zigrupt is a inter-thread event broadcasting library for Zig.
//!
//! Single or concurrent producers publish events for every registered handler to
//! process in order on its own thread. Supports batched consumption, custom
//! waiting strategies, draining, and restart.

const std = @import("std");

/// Event bus types, callbacks, lifecycle states, and errors.
pub const event_bus = @import("event_bus.zig");

pub const event_processing = @import("event_processing.zig");

/// Creates a ring-buffer bus type; see `EventBus` in `event_bus.zig` for configuration and lifecycle requirements.
pub const EventBus = event_bus.EventBus;

/// Callback type that acknowledges a consumed prefix of an event batch.
pub const EventHandler = event_processing.EventHandler;

/// Fixed-capacity ring-buffer storage.
pub const ring_buffer = @import("ring_buffer.zig");

/// Fixed-capacity event storage indexed by sequence.
pub const RingBuffer = ring_buffer.RingBuffer;

/// Sequence claims, publication tracking, consumer progress, and slot-reuse coordination.
pub const sequencer = @import("sequencer.zig");

/// Built-in waiting strategies and validation for custom strategies.
pub const waiting_strategy = @import("waiting_strategy.zig");

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(event_bus);
    std.testing.refAllDecls(ring_buffer);
    std.testing.refAllDecls(sequencer);
    std.testing.refAllDecls(waiting_strategy);
}
