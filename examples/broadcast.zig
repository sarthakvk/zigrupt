const std = @import("std");
const zigrupt = @import("zigrupt");

// Separate storage for each handler. Main reads only after both threads join.
const Audit = struct {
    var next: usize = 0;
    fn handle(events: []const usize) usize {
        for (events) |event| {
            if (event != next) @panic("audit received an unexpected sequence");
            next += 1;
        }
        return events.len;
    }
};
const Metrics = struct {
    var count: usize = 0;
    var sum: usize = 0;
    fn handle(events: []const usize) usize {
        for (events) |event| {
            count += 1;
            sum += event;
        }
        return events.len;
    }
};
const Bus = zigrupt.EventBus(usize, false, &.{ Audit.handle, Metrics.handle }, zigrupt.waiting_strategy.BusySpin, zigrupt.waiting_strategy.BusySpin);

pub fn main() !void {
    var bus = try Bus.init(std.heap.page_allocator, 8, 4);
    defer bus.deinit();
    try bus.start();
    errdefer bus.stop() catch {};
    for (0..100) |value| try bus.produce(value);
    try bus.stop();
    if (Audit.next != 100 or Metrics.count != 100 or Metrics.sum != 4950)
        return error.UnexpectedDelivery;
    std.debug.print("broadcast: both handlers received 100 events\n", .{});
}
