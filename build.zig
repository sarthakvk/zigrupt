const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const zigrupt = b.addModule("zigrupt", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
    });

    const bench_exe = b.addExecutable(.{ .name = "ring-buffer-benchmark", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/ring_buffer.zig"),
        .optimize = .ReleaseFast,
        .target = target,
    }) });
    bench_exe.root_module.addImport("zigrupt", b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .optimize = .ReleaseFast,
        .target = target,
    }));
    const bench_cmd = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_cmd.addArgs(args);
    const bench_step = b.step("bench", "Benchmark ring buffer throughput and latency (ReleaseFast)");
    bench_step.dependOn(&bench_cmd.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = zigrupt })).step);

    var test_dir = b.build_root.handle.openDir(b.graph.io, "test", .{ .iterate = true }) catch @panic("cannot open test directory");
    defer test_dir.close(b.graph.io);
    var test_files = test_dir.iterate();
    while (test_files.next(b.graph.io) catch @panic("cannot iterate test directory")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.pathJoin(&.{ "test", entry.name })),
            .optimize = optimize,
            .target = target,
        }) });
        tests.root_module.addImport("zigrupt", zigrupt);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
