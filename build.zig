const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const zigrupt = b.addModule("zigrupt", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
    });

    const bench_exe = b.addExecutable(.{ .name = "benchmark", .root_module = b.createModule(.{
        .root_source_file = b.path("test/benchmark.zig"),
        .optimize = optimize,
        .target = target,
    }) });

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/disruptor.zig"),
        .optimize = optimize,
        .target = target,
    }) });
    tests.root_module.addImport("zigrupt", zigrupt);

    const source_tests = b.addTest(.{ .root_module = zigrupt });

    const ring_buffer_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/ring_buffer_single_producer.zig"),
        .optimize = optimize,
        .target = target,
    }) });
    ring_buffer_tests.root_module.addImport("zigrupt", zigrupt);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(source_tests).step);
    test_step.dependOn(&b.addRunArtifact(ring_buffer_tests).step);

    bench_exe.root_module.addImport("zigrupt", zigrupt);

    const bench_cmd = b.addRunArtifact(bench_exe);

    // pass args to bench
    if (b.args) |args| bench_cmd.addArgs(args);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}
