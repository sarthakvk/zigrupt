const std = @import("std");
const zigrupt = @import("zigrupt");

const Event = struct { value: usize };
var total: usize = 0; // Only the handler writes; main reads after stop joins it.

fn handle(events: []const Event) usize {
    for (events) |event| total += event.value;
    return events.len;
}

const Bus = zigrupt.EventBus(
    Event,
    false,
    &.{handle},
    zigrupt.waiting_strategy.BusySpin,
    zigrupt.waiting_strategy.BusySpin,
);

pub fn main() !void {
    var bus = try Bus.init(std.heap.page_allocator, 64, 8);
    defer bus.deinit();
    try bus.start();
    errdefer bus.stop() catch {}; // Drain before freeing on a publishing error.

    for (1..11) |value| try bus.produce(.{ .value = value });
    try bus.stop(); // Publishing is finished; drain and join the handler.

    if (total != 55) return error.UnexpectedTotal;
    std.debug.print("basic: sum = {d}\n", .{total});
}
