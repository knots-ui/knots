const std = @import("std");
const knots = @import("knots");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const knots_dep = b.dependency("knots", .{ .target = target, .optimize = optimize });

    const executable = b.addExecutable(.{
        .name = "embedded",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "knots-ui", .module = knots_dep.module("ui") },
                .{ .name = "knots-renderer", .module = knots_dep.module("renderer") },
                .{ .name = "knots-window", .module = knots_dep.module("window") },
            },
        }),
    });

    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("run", "Run the bounded embedding example").dependOn(&run.step);
}
