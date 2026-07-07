const std = @import("std");
const Knots = @import("knots");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const knots = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("triangle", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{.{ .name = "knots", .module = knots.module("knots") }},
    });

    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "knots", .module = knots.module("knots") },
            .{ .name = "triangle", .module = mod },
        },
    });

    const exe = b.addExecutable(.{ .name = "triangle", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the triangle app");

    if (isBrowserWasmTarget(target.result)) {
        exe.entry = .disabled;

        Knots.installWeb(b, knots, exe_mod, exe, .{ .index_html = b.path("src/shell_wasm.html") });

        const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", "8000", "--directory" });
        serve.addArg("zig-out/web");
        serve.step.dependOn(b.getInstallStep());
        run_step.dependOn(&serve.step);
    } else {
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);

        run_cmd.step.dependOn(b.getInstallStep());

        run_cmd.addPassthruArgs();
    }
}

fn isBrowserWasmTarget(target: std.Target) bool {
    return target.cpu.arch.isWasm() and target.os.tag == .freestanding;
}
