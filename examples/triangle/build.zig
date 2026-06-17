const std = @import("std");
const GPUBackend = @import("knots").GPUBackend;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    const gpu_backend: GPUBackend = switch (target.result.os.tag) {
        .macos, .emscripten => .wgpu,
        .windows, .linux => .vulkan,
        else => .wgpu,
    };

    const knots = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
        .gpu_backend = gpu_backend,
    });

    const exe = b.addExecutable(.{
        .name = "playground",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{.{ .name = "knots", .module = knots.module("knots") }},
        }),
    });

    if (optimize != .Debug) exe.subsystem = .windows;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the triangle app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
