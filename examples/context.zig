const std = @import("std");
const zigrupt = @import("zigrupt");

const Context = struct {
    // Two handler threads update this same object, so the counter is atomic.
    bytes_seen: std.atomic.Value(usize) = .init(0),
};
const Event = struct { context: *Context, text: []const u8 };

fn handle(events: []const Event) usize {
    for (events) |event| {
        _ = event.context.bytes_seen.fetchAdd(event.text.len, .monotonic);
    }
    return events.len;
}
const Bus = zigrupt.EventBus(Event, false, &.{ handle, handle }, zigrupt.waiting_strategy.BusySpin, zigrupt.waiting_strategy.BusySpin);

pub fn main() !void {
    var context: Context = .{};
    // The slice points into separately owned storage; produce does not copy it.
    const text = try std.heap.page_allocator.dupe(u8, "hello");
    defer std.heap.page_allocator.free(text);

    var bus = try Bus.init(std.heap.page_allocator, 8, 4);
    defer bus.deinit();
    try bus.start();
    errdefer bus.stop() catch {};
    for (0..10) |_| try bus.produce(.{ .context = &context, .text = text });
    try bus.stop(); // Both context and text outlive every handler access.

    const bytes = context.bytes_seen.load(.monotonic);
    if (bytes != 100) return error.UnexpectedByteCount;
    std.debug.print("context: two handlers counted {d} bytes\n", .{bytes});
}
