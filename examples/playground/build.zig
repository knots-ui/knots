const std = @import("std");
const Knots = @import("knots");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    const web_threads = b.option(bool, "web_threads", "Enable worker threads in the web playground.") orelse false;
    const gpu_backend = b.option(Knots.GPUBackend, "gpu_backend", "GPU backend to compile into knots.") orelse defaultGpuBackend(target.result);
    const knots = b.dependency("knots", .{
        .target = target,
        .optimize = optimize,
        .web_threads = web_threads,
        .gpu_backend = gpu_backend,
    });

    const exe = buildExecutable(b, target, optimize, gpu_backend, knots, "playground");
    b.installArtifact(exe);
    const run = if (target.result.cpu.arch.isWasm()) blk: {
        exe.entry = .disabled;
        Knots.installWeb(b, knots, exe.root_module, exe, .{ .index_html = b.path("src/shell_wasm.html") });
        const run = webServer(b, web_threads, "zig-out/web");
        run.step.dependOn(b.getInstallStep());
        break :blk run;
    } else blk: {
        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        break :blk run;
    };

    b.step("run", "Run the standalone browser playground").dependOn(&run.step);

    const dev = Knots.HMR.init(b, .{
        .target = target,
        .gpu_backend = gpu_backend,
        .threads = true,
        .web = .{ .index_html = b.path("src/shell_wasm.html") },
    });
    const dev_exe = buildExecutable(b, dev.target, dev.optimize, gpu_backend, dev.knots, "playground-dev");
    dev.addRunner(dev_exe, b.step("dev", "Run the playground with HMR"));
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

fn buildExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, gpu_backend: Knots.GPUBackend, knots: *std.Build.Dependency, name: []const u8) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "knots", .module = knots.module("knots") },
            .{ .name = "knots-ui", .module = knots.module("ui") },
            .{ .name = "renderer", .module = knots.module("renderer") },
        },
    });
    var shader_config = b.addOptions();
    shader_config.addOption(bool, "has_wgsl", gpu_backend == .webgpu);
    shader_config.addOption(bool, "has_spirv", gpu_backend == .vulkan);
    mod.addOptions("gpu_shader_config", shader_config);
    if (gpu_backend == .webgpu)
        mod.addAnonymousImport("gpu_shader_wgsl", .{ .root_source_file = b.path("src/shaders/gpu_shader.wgsl") });
    if (gpu_backend == .vulkan) {
        embedSpirV(b, optimize, mod, knots, "gpu_shader_vert_spv", b.path("src/shaders/gpu_shader_vertex.zig"));
        embedSpirV(b, optimize, mod, knots, "gpu_shader_frag_spv", b.path("src/shaders/gpu_shader_fragment.zig"));
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "knots", .module = knots.module("knots") },
            .{ .name = "playground", .module = mod },
        },
    });

    const exe = b.addExecutable(.{ .name = name, .root_module = exe_mod });
    return exe;
}

fn defaultGpuBackend(target: std.Target) Knots.GPUBackend {
    if (target.cpu.arch.isWasm()) return .webgpu;
    return switch (target.os.tag) {
        .macos => .webgpu,
        .windows, .linux => .vulkan,
        else => @panic("unsupported playground target"),
    };
}

fn embedSpirV(b: *std.Build, optimize: std.builtin.OptimizeMode, mod: *std.Build.Module, knots: *std.Build.Dependency, name: []const u8, path: std.Build.LazyPath) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .spirv32,
        .os_tag = .vulkan,
        .cpu_model = .{ .explicit = &std.Target.spirv.cpu.vulkan_v1_2 },
    });
    const shader_common = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = knots.path("src/gpu/backend/vulkan/shaders/common.zig"),
    });
    const shader = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = path,
            .imports = &.{.{ .name = "shader_common", .module = shader_common }},
        }),
        .use_llvm = false,
    });
    mod.addAnonymousImport(name, .{ .root_source_file = shader.getEmittedBin() });
}
