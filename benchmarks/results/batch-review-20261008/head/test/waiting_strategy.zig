const std = @import("std");
const waiting_strategy = @import("zigrupt").waiting_strategy;

test "BusySpin satisfies the waiting strategy contract" {
    comptime waiting_strategy.validateWaitingStrategy(waiting_strategy.BusySpin);
    waiting_strategy.BusySpin.wait();
}

test "a custom zero-argument wait function satisfies the contract" {
    const CountingStrategy = struct {
        var calls: usize = 0;

        pub fn wait() void {
            calls += 1;
        }
    };

    comptime waiting_strategy.validateWaitingStrategy(CountingStrategy);
    CountingStrategy.wait();
    try std.testing.expectEqual(@as(usize, 1), CountingStrategy.calls);
}
