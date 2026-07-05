const std = @import("std");
const GPUBackend = @import("knots").GPUBackend;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gpu_backend: GPUBackend = if (isBrowserWasmTarget(target.result))
        .webgpu
    else switch (target.result.os.tag) {
        .macos => .webgpu,
        .windows, .linux => .vulkan,
        else => .webgpu,
    };

    const tracy_dep = b.dependency("tracy", .{});

    const tracy_lib = b.addLibrary(.{
        .name = "tracy",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    tracy_lib.root_module.addCSourceFile(.{
        .file = tracy_dep.path("public/TracyClient.cpp"),
        .flags = &.{
            "-DTRACY_ENABLE",
            "-std=c++17",
            "-fno-sanitize=all",
        },
    });
    switch (target.result.os.tag) {
        .windows => {
            tracy_lib.root_module.linkSystemLibrary("dbghelp", .{});
        },
        else => {},
    }
    tracy_lib.root_module.link_libcpp = true;

    const tracy_c = b.addTranslateC(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = tracy_dep.path("public/tracy/TracyC.h"),
    });
    tracy_c.defineCMacro("TRACY_ENABLE", null);
    const tracy_mod = tracy_c.createModule();

    const knots = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
        .gpu_backend = gpu_backend,
    });

    const exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "knots", .module = knots.module("knots") },
                .{ .name = "tracy", .module = tracy_mod },
            },
        }),
    });
    exe.root_module.linkLibrary(tracy_lib);

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

fn isBrowserWasmTarget(target: std.Target) bool {
    const is_wasm = switch (target.cpu.arch) {
        .wasm32, .wasm64 => true,
        else => false,
    };
    return is_wasm and target.os.tag == .freestanding;
}
