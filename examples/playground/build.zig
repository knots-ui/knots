const std = @import("std");
const GPUBackend = @import("knots").GPUBackend;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const knots = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("playground", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{.{ .name = "knots", .module = knots.module("knots") }},
    });

    const exe_mod = b.createModule(.{
        .root_source_file = switch (target.result.os.tag) {
            .emscripten => b.path("src/main_web.zig"),
            else => b.path("src/main.zig"),
        },
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "playground", .module = mod }},
    });

    if (target.result.os.tag == .emscripten) {
        buildEmscripten(b, target, optimize, exe_mod);
        return;
    }

    const exe = b.addExecutable(.{
        .name = "playground",
        .root_module = exe_mod,
    });

    if (optimize != .Debug) exe.subsystem = .windows;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the playground app");

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

fn buildEmscripten(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, root_module: *std.Build.Module) void {
    const emcc_path =
        b.option([]const u8, "emcc", "Path to emcc. Defaults to searching PATH.") orelse b.findProgram(&.{"emcc"}, &.{}) catch
            @panic("emcc not found. Put emcc on PATH or pass -Demcc=/path/to/emcc.");

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "playground",
        .root_module = root_module,
    });
    lib.entry = .disabled;

    const emcc = b.addSystemCommand(&.{emcc_path});
    emcc.addArtifactArg(lib);
    emcc.addArg("-o");
    const html_out = emcc.addOutputFileArg("playground.html");

    var args = std.ArrayList([]const u8).initCapacity(b.allocator, 32) catch @panic("OOM");
    defer args.deinit(b.allocator);
    args.appendSliceAssumeCapacity(&.{
        "--use-port=emdawnwebgpu",
        "-sUSE_GLFW=3",
        "-sALLOW_MEMORY_GROWTH=1",
        "-sEXIT_RUNTIME=0",
        "-sASYNCIFY",
        "-sASYNCIFY_STACK_SIZE=65536",
        "-sSTACK_SIZE=4194304",
        "-sINITIAL_MEMORY=33554432",
    });
    if (optimize == .Debug) args.appendAssumeCapacity("-sASSERTIONS=2");
    if (target.result.cpu.arch == .wasm64) args.appendAssumeCapacity("-sMEMORY64");
    args.appendAssumeCapacity("--shell-file");

    emcc.addArgs(args.items);
    emcc.addFileArg(b.path("src/shell.html"));

    const install_html = b.addInstallFileWithDir(html_out, .{ .custom = "web" }, "index.html");
    const install_js = b.addInstallFileWithDir(html_out.dirname().path(b, "playground.js"), .{ .custom = "web" }, "playground.js");
    const install_wasm = b.addInstallFileWithDir(html_out.dirname().path(b, "playground.wasm"), .{ .custom = "web" }, "playground.wasm");

    b.getInstallStep().dependOn(&install_html.step);
    b.getInstallStep().dependOn(&install_js.step);
    b.getInstallStep().dependOn(&install_wasm.step);

    const serve_step = b.step("run", "Serve the playground on http://localhost:8000/");
    const serve = b.addSystemCommand(&.{ "python3", "-m", "http.server", "8000", "--directory" });
    serve.addArg(b.getInstallPath(.{ .custom = "web" }, ""));
    serve.step.dependOn(b.getInstallStep());
    serve_step.dependOn(&serve.step);
}
