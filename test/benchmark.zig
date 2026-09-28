const std = @import("std");
const zigrupt = @import("zigrupt");
const Disruptor = zigrupt.Disruptor;

const IntDisruptor = Disruptor(usize, .{
    .consumer_count = 1,
    .publisher_count = 1,
    .buffer_size = 8,
});

pub fn main() void {
    var prng = std.Random.DefaultPrng.init(12412);
    const rand = prng.random();
    var disruptor: IntDisruptor = .{};
    std.debug.print("Running benchmarks...\n", .{});

    for (0..20) |i| {
        if (i >= 8) {
            if (disruptor.consume(0)) |out| {
                std.debug.print("Consumed: {d}\n", .{out});
            } else {
                std.debug.print("Failed to consume\n", .{});
            }
        } else {
            const rnd = rand.int(usize);
            disruptor.publish(rnd);
            std.debug.print("Published {d}\n", .{rnd});
        }
        disruptor.printState();
    }
}
