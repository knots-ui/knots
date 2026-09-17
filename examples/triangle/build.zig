const std = @import("std");
const Knots = @import("knots");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const knots = b.dependency("knots", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("triangle", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "knots", .module = knots.module("knots") },
            .{ .name = "knots-ui", .module = knots.module("ui") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "triangle",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "knots", .module = knots.module("knots") },
                .{ .name = "triangle", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the triangle app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();
}
