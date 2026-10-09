const std = @import("std");
const zigrupt = @import("zigrupt");

var next: usize = 0;
var retried: bool = false;

fn handle(events: []const usize) usize {
    if (events.len == 0 or events.len > 8) @panic("unexpected batch size");
    if (!retried) {
        retried = true;
        return 0; // No side effects on events; retry this prefix once.
    }
    // Process at most two events even if a larger contiguous batch is offered.
    const consumed = @min(events.len, 2);
    for (events[0..consumed]) |event| {
        if (event != next) @panic("unexpected event or duplicate processing");
        next += 1;
    }
    return consumed; // Acknowledge exactly the prefix processed above.
}
const Bus = zigrupt.EventBus(usize, false, &.{handle}, zigrupt.waiting_strategy.BusySpin, zigrupt.waiting_strategy.BusySpin);

pub fn main() !void {
    var bus = try Bus.init(std.heap.page_allocator, 16, 8);
    defer bus.deinit();
    try bus.start();
    errdefer bus.stop() catch {};
    for (0..100) |value| try bus.produce(value);
    try bus.stop();
    if (next != 100 or !retried) return error.UnexpectedConsumption;
    std.debug.print("batching: 100 events consumed in order after one retry\n", .{});
}
