const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const watch = b.addModule("watch", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(b, watch, target);

    const tests = b.addTest(.{ .root_module = watch });
    const test_step = b.step("test", "Run watcher tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn configureModule(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .macos => {
            module.linkFramework("CoreFoundation", .{});
            module.linkFramework("CoreServices", .{});
        },
        .windows => {
            const win32 = b.dependency("win32", .{});
            module.addImport("win32", win32.module("win32"));
        },
        else => {},
    }
}
