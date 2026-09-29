const std = @import("std");

pub const DisruptorOptions = struct {
    consumer_count: usize = 2,
    publisher_count: usize = 1,
};

const PaddedSeq = struct {
    value: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(1),
};

const buffer_size = 2048;
const max_consumer_count = 128;

pub const DisruptorError = error{
    TooManyConsumers,
};

pub fn Disruptor(
    comptime T: type,
) type {
    return struct {
        options: DisruptorOptions,
        buffer: [buffer_size]T = undefined,
        buffer_seq: [buffer_size]std.atomic.Value(usize) = @splat(std.atomic.Value(usize).init(0)),
        p_seq: PaddedSeq = .{},
        c_seqs: [max_consumer_count]PaddedSeq = @splat(.{}),
        const mask: usize = buffer_size - 1;
        const Self = @This();

        pub fn init(options: DisruptorOptions) DisruptorError!Self {
            if (options.consumer_count > max_consumer_count) return DisruptorError.TooManyConsumers;
            return .{
                .options = options,
            };
        }

        pub fn publish(self: *Self, data: T) void {
            var p_seq = self.p_seq.value.load(.monotonic);

            if (self.options.publisher_count > 1) {
                while (true) {
                    p_seq = self.p_seq.value.cmpxchgWeak(p_seq, p_seq + 1, .monotonic, .monotonic) orelse break;
                }
            } else {
                self.p_seq.value.store(p_seq + 1, .monotonic);
            }

            while (self.isSlotSafeToWrite(p_seq)) {
                continue;
            }

            self.buffer[(p_seq & mask)] = data;
            self.buffer_seq[(p_seq & mask)].store(p_seq, .release);
        }

        pub fn consume(self: *Self, consumer_id: usize) ?T {
            //TODO: do we need atomics, if consumer seq is written by the same thread?
            const c_seq = self.c_seqs[consumer_id].value.load(.monotonic);

            const buffer_seq = self.buffer_seq[(c_seq & mask)].load(.acquire);

            if (buffer_seq == 0 or buffer_seq < c_seq) {
                return null;
            }

            const data = self.buffer[(c_seq & mask)];
            self.c_seqs[consumer_id].value.store(c_seq + 1, .release);
            return data;
        }

        pub fn printState(self: *Self) void {
            std.debug.print("---------------\n", .{});
            std.debug.print("p_seq: {d}, mask: {d}\n", .{ self.p_seq.load(.monotonic), mask });
            for (&self.c_seqs, 0..) |*seq, i| {
                std.debug.print("c_seqs[{d}]: {d}\n", .{ i, seq.value.load(.monotonic) });
            }
            for (&self.buffer_seq, 0..) |*seq, i| {
                const value = seq.load(.acquire);
                std.debug.print("buffer_seq[{d}]: {d}\n", .{ i, value });
                if (value != 0) {
                    std.debug.print("buffer[{d}]: {any}\n", .{ i, self.buffer[i] });
                }
            }
            std.debug.print("---------------\n\n", .{});
        }

        fn isSlotSafeToWrite(self: *Self, seq: usize) bool {
            // Here we check that the slowest consumer sequence is strictly
            // greater than `seq - buffer_size`, for the reasons as follows
            //
            // We want to make sure that the slot is safe is write i.e
            // All the consumers have consumed the data from the slot as well as
            // no other publisher have acquire the slot but haven't  released it yet.
            for (0..self.options.consumer_count) |c| {
                const c_seq = &self.c_seqs[c];
                const consumed_till = c_seq.value.load(.acquire);
                if (consumed_till <= std.math.sub(usize, seq, buffer_size) catch 0) {
                    return true;
                }
            }
            return false;
        }
    };
}
