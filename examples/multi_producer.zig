const std = @import("std");
const zigrupt = @import("zigrupt");

const producer_count = 3;
const events_per_producer = 100;
const Event = struct { producer: usize, offset: usize };
var next: [producer_count]usize = @splat(0);

fn handle(events: []const Event) usize {
    for (events) |event| {
        // Cross-producer interleaving is unspecified; each producer stays ordered.
        if (event.offset != next[event.producer])
            @panic("unexpected producer order");
        next[event.producer] += 1;
    }
    return events.len;
}
const Bus = zigrupt.EventBus(
    Event,
    true,
    &.{handle},
    zigrupt.waiting_strategy.BusySpin,
    zigrupt.waiting_strategy.BusySpin,
);

const Publisher = struct {
    bus: *Bus,
    id: usize,
    failure: ?anyerror = null, // Read only after this publisher is joined.

    fn run(self: *Publisher) void {
        for (0..events_per_producer) |offset| {
            self.bus.produce(.{
                .producer = self.id,
                .offset = offset,
            }) catch |err| {
                self.failure = err;
                return;
            };
        }
    }
};

pub fn main() !void {
    var bus = try Bus.init(std.heap.page_allocator, 16, 8);
    defer bus.deinit();
    try bus.start();
    errdefer bus.stop() catch {};

    var publishers: [producer_count]Publisher = undefined;
    {
        var threads: [producer_count]std.Thread = undefined;
        var started: usize = 0;
        // Also join already-spawned producers if a later spawn fails.
        // This scope exits before the bus's error cleanup calls stop.
        defer for (threads[0..started]) |thread| thread.join();
        for (&publishers, 0..) |*publisher, id| {
            publisher.* = .{ .bus = &bus, .id = id };
            threads[started] = try std.Thread.spawn(.{}, Publisher.run, .{publisher});
            started += 1;
        }
    }
    try bus.stop(); // Every producer has joined, so draining is safe.
    for (publishers) |publisher| if (publisher.failure) |err| return err;
    for (next) |count| if (count != events_per_producer) return error.MissingEvents;
    std.debug.print("multi_producer: 300 events, each producer ordered\n", .{});
}
