const std = @import("std");
const zigrupt = @import("zigrupt");

const Yield = struct {
    // A static zero-argument function, with no self pointer or error return.
    pub fn wait() void {
        std.Thread.yield() catch {};
    }
};
comptime {
    zigrupt.waiting_strategy.validateWaitingStrategy(Yield);
}

var count: usize = 0;
fn handle(events: []const usize) usize {
    count += events.len;
    return events.len;
}
const Bus = zigrupt.EventBus(usize, false, &.{handle}, Yield, Yield);

pub fn main() !void {
    var bus = try Bus.init(std.heap.page_allocator, 8, 4);
    defer bus.deinit();
    try bus.start();
    errdefer bus.stop() catch {};
    for (0..100) |value| try bus.produce(value);
    try bus.stop();
    if (count != 100) return error.MissingEvents;
    std.debug.print("waiting_strategy: 100 events delivered using Yield\n", .{});
}
