---
title: Getting started
description: Install zigrupt with Zig 0.16.0 and run a complete program.
---

Use **Zig 0.16.0**, the declared minimum and the version checked in CI. Newer
versions need verification before assuming compatibility. Node is only required
to build this documentation website, not to install or use the Zig library.

## Install in a new project

The public distribution route is a GitHub source archive. Once the repository is
public, initialize a consumer and fetch the dependency:

```sh
mkdir zigrupt-demo
cd zigrupt-demo
zig init --minimal
zig fetch --save=zigrupt https://github.com/sarthakvk/zigrupt/archive/refs/heads/main.tar.gz
mkdir -p src
```

`zig fetch` writes a `zigrupt` entry under `.dependencies` in `build.zig.zon`,
including its URL and computed content hash. Commit that manifest. `main` moves;
for reproducible updates, use
`https://github.com/sarthakvk/zigrupt/archive/<full-commit-sha>.tar.gz`, replacing
the placeholder with a reviewed commit SHA. Package version 0.0.1 does not imply
that a matching release tag exists.

Before public availability, use the [checkout installation](#install-from-a-checkout)
below, then continue with the same build file and program.

Replace the generated `build.zig` with this canonical consumer build file:

<!-- snippet: examples/consumer/build.zig -->
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigrupt = b.dependency("zigrupt", .{
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "zigrupt-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigrupt", .module = zigrupt.module("zigrupt") }},
        }),
    });
    b.installArtifact(exe);
    b.step("run", "Run the consumer").dependOn(&b.addRunArtifact(exe).step);
}
```
<!-- end:examples/consumer/build.zig -->

The dependency key, `b.dependency("zigrupt", ...)`, module name, and import name
must agree. Merely adding the dependency manifest does not expose the module to
your executable.

## First program

Save this as `src/main.zig`:

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

Run it:

```sh
zig build run
```

Expected output on stderr: `basic: sum = 55`.

The handler runs on its own thread. `produce()` publishes a value, but does not
wait for handler completion. Finishing production and then calling `stop()`
drains the bus and joins the handler before main reads its result. `deinit()`
releases the bus's allocations afterward.

## Install from a checkout

This route works before public availability and for offline development after
obtaining a checkout. Clone using your configured repository access, or use an
existing checkout. From its parent directory:

```sh
mkdir -p zigrupt-demo/vendor
git -C zigrupt archive --format=tar.gz --output=../zigrupt-demo/vendor/zigrupt.tar.gz HEAD
cd zigrupt-demo
zig init --minimal
zig fetch --save=zigrupt vendor/zigrupt.tar.gz
mkdir -p src
```

Use the same `build.zig` and `src/main.zig` above, then run `zig build run`.
Commit the archive along with the generated manifest so other machines can
resolve the dependency. `git archive` packages a committed revision, excluding
uncommitted changes; substitute a reviewed commit SHA for `HEAD` when needed.

## Run examples from a checkout

```sh
zig build example-basic
zig build check-examples
```

The [six examples](https://github.com/sarthakvk/zigrupt/tree/main/examples) each
check their results. `python3 scripts/check-install.py` additionally verifies a
hashed archive dependency in a temporary consumer outside the checkout. It uses
the exact build file and program above, and does not require network access.
The check validates package layout, dependency resolution, import, compilation,
and execution. Public GitHub downloading can be verified once the repository
is public; the local check does not depend on its visibility.

Continue with [concepts](/zigrupt/concepts/) and
[event ownership](/zigrupt/guides/ownership/) before passing pointers or slices.
