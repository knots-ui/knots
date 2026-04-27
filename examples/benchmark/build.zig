const std = @import("std");
const GPUBackend = @import("knots").GPUBackend;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const knots = b.dependency("knots", .{
        .target = target,
        .optimize = .ReleaseSafe,
        .gpu_backends = &[_]GPUBackend{ .wgpu, .vulkan },
    });

    const exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseSafe,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{.{ .name = "knots", .module = knots.module("knots") }},
        }),
    });

    if (target.result.os.tag == .windows) exe.subsystem = .windows;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the benchmark app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
