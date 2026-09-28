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

    bench_exe.root_module.addImport("zigrupt", zigrupt);

    const bench_cmd = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}
