# zigrupt

A Disruptor-inspired event bus for Zig. Producers publish into a fixed-capacity
ring buffer; independent handlers each receive the same ordered stream. It is
useful when several consumers need every event and the slowest consumer should
apply backpressure to producers.

zigrupt is under active development (package version 0.0.1). The API may change.
The current implementation supports single/multi-producer operation, broadcast
handlers, batching, custom waiting strategies, draining, and restart. This is a
starting point for the library, not its final scope or a claim of full LMAX parity.

**Use Zig 0.16.0.** Building or using the library does not require Node.

## Install

In a Zig project, once the repository is public:

```sh
zig fetch --save=zigrupt https://github.com/sarthakvk/zigrupt/archive/refs/heads/main.tar.gz
```

Commit the generated dependency URL and hash. For reproducible updates, use
`https://github.com/sarthakvk/zigrupt/archive/<full-commit-sha>.tar.gz` with a
reviewed commit. Add
`b.dependency("zigrupt", .{ .target = target, .optimize = optimize }).module("zigrupt")`
as the executable's `zigrupt` import. See the
[complete installation guide](docs/getting-started.md) and
[consumer build file](examples/consumer/build.zig) for the full setup, including
installation from a checkout before public availability.

## First program

This is the executable [basic example](examples/basic.zig):

<!-- snippet: examples/basic.zig -->
```zig
const std = @import("std");
const zigrupt = @import("zigrupt");

const Event = struct { value: usize };
var total: usize = 0; // Only the handler writes; main reads after stop joins it.

fn handle(events: []const Event) usize {
    for (events) |event| total += event.value;
    return events.len;
}

const Bus = zigrupt.EventBus(Event, false, &.{handle}, zigrupt.waiting_strategy.BusySpin, zigrupt.waiting_strategy.BusySpin);

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
```
<!-- end:examples/basic.zig -->

From a checkout, run `zig build example-basic`; expected output is
`basic: sum = 55`. `zig build check-examples` runs all six examples and checks
results.

Handlers run on separate threads. Returning a count acknowledges a consumed
prefix. Event values are copied, but pointers/slices inside them still refer to
caller-owned storage. Finish and join every producer before `stop()`, keep
referenced data alive through consumption, and stop before `deinit()`.

## Documentation and development

- [Full documentation source](docs/index.md), [concepts](docs/concepts.md), and [API reference](docs/reference/api.md).
- [Executable examples](examples/README.md) and [existing behavior tests](test/): `zig build test`.
- [Benchmark methodology and caveats](benchmarks/README.md): `devbox run bench --standalone --smoke` for a short Zig-only check on Linux.
- [Contributing](CONTRIBUTING.md), including formatting, installation verification, and documentation checks.
- [Documentation preview/build instructions](CONTRIBUTING.md#documentation-workflow). A GitHub Pages configuration is prepared; no published documentation URL is assumed until hosting is enabled and deployment succeeds.
- [MIT license](LICENSE).
