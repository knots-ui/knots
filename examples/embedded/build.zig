const std = @import("std");
const Knots = @import("knots");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const knots = b.dependency("knots", .{ .target = target, .optimize = optimize });

    const executable = b.addExecutable(.{
        .name = "embedded",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "knots-ui", .module = knots.module("ui") },
                .{ .name = "knots-renderer", .module = knots.module("renderer") },
                .{ .name = "knots-window", .module = knots.module("window") },
            },
        }),
    });

    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("run", "Run the bounded embedding example").dependOn(&run.step);
}
