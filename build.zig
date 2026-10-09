const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const zigrupt = b.addModule("zigrupt", .{
        .root_source_file = b.path("src/root.zig"),
        .optimize = optimize,
        .target = target,
    });

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
