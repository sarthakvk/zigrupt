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
