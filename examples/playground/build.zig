const std = @import("std");
const Knots = @import("knots");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const knots = b.dependency("knots", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("playground", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "knots", .module = knots.module("knots") }},
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "knots", .module = knots.module("knots") },
            .{ .name = "playground", .module = mod },
        },
    });

    const exe = b.addExecutable(.{ .name = "playground", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the playground app");

    if (isBrowserWasmTarget(target.result)) {
        exe.entry = .disabled;

        Knots.installWeb(b, knots, exe_mod, exe, .{ .index_html = b.path("src/shell_wasm.html") });

        const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", "8000", "--directory" });
        serve.addArg(b.getInstallPath(.{ .custom = "web" }, ""));
        serve.step.dependOn(b.getInstallStep());
        run_step.dependOn(&serve.step);
    } else {
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const mod_tests = b.addTest(.{
            .root_module = mod,
        });

        const run_mod_tests = b.addRunArtifact(mod_tests);

        const exe_tests = b.addTest(.{
            .root_module = exe.root_module,
        });

        const run_exe_tests = b.addRunArtifact(exe_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
        test_step.dependOn(&run_exe_tests.step);
    }
}

fn isBrowserWasmTarget(target: std.Target) bool {
    return target.cpu.arch.isWasm() and target.os.tag == .freestanding;
}
