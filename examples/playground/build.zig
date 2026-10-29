const std = @import("std");
const Knots = @import("knots");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});

    const web_threads = b.option(bool, "web_threads", "Enable worker threads in the web playground.") orelse false;
    // Decides the shader language the GPU demo needs: WGSL for WebGPU, SPIR-V for Vulkan.
    const gpu_backend = Knots.defaultGpuBackend(target.result);

    const knots_dep = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
        .web_threads = web_threads,
        .gpu_backend = gpu_backend,
    });

    const exe = buildExecutable(b, target, optimize, gpu_backend, knots_dep, "playground");
    b.installArtifact(exe);

    const run = if (target.result.cpu.arch.isWasm()) blk: {
        exe.entry = .disabled;
        Knots.installWeb(b, knots_dep, exe.root_module, exe, .{ .index_html = b.path("src/shell_wasm.html") });
        const run = webServer(b, web_threads, "zig-out/web");
        run.step.dependOn(b.getInstallStep());
        break :blk run;
    } else blk: {
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        break :blk run;
    };

    b.step("run", "Run the standalone browser playground").dependOn(&run.step);

    const dev = b.step("dev", "Rebuild and restart the app on every save");
    Knots.addDevWatcher(b, knots_dep, dev, exe, .{});
}

fn webServer(b: *std.Build, web_threads: bool, directory: []const u8) *std.Build.Step.Run {
    if (web_threads) {
        const command = b.addSystemCommand(&.{"python3"});
        command.addFileArg(b.path("serve.py"));
        command.addArgs(&.{ "--port", "8000", "--directory", directory });
        return command;
    }

    return b.addSystemCommand(&.{ "python3", "-m", "http.server", "8000", "--directory", directory });
}

fn buildExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, gpu_backend: Knots.GPUBackend, knots_dep: *std.Build.Dependency, name: []const u8) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "knots", .module = knots_dep.module("knots") },
            .{ .name = "knots-ui", .module = knots_dep.module("ui") },
            .{ .name = "renderer", .module = knots_dep.module("renderer") },
        },
    });
    // The GPU demo's shader, in the language of the backend.
    switch (gpu_backend) {
        .webgpu => mod.addAnonymousImport("gpu_shader_wgsl", .{ .root_source_file = b.path("src/shaders/gpu_shader.wgsl") }),
        .vulkan => {
            mod.addAnonymousImport("gpu_shader_vertex", .{ .root_source_file = Knots.addSpirV(knots_dep, optimize, b.path("src/shaders/gpu_shader_vertex.zig")) });
            mod.addAnonymousImport("gpu_shader_fragment", .{ .root_source_file = Knots.addSpirV(knots_dep, optimize, b.path("src/shaders/gpu_shader_fragment.zig")) });
        },
    }
    return b.addExecutable(.{ .name = name, .root_module = mod });
}
