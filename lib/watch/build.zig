const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const watch = b.addModule("watch", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    switch (target.result.os.tag) {
        .macos => watch.linkFramework("CoreServices", .{}),
        .windows => if (b.lazyDependency("win32", .{})) |win32| watch.addImport("win32", win32.module("win32")),
        else => {},
    }

    const tests = b.addTest(.{ .root_module = watch });
    b.step("test", "Test the watcher").dependOn(&b.addRunArtifact(tests).step);
}
