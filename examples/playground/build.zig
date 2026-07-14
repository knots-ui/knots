const std = @import("std");
const Knots = @import("knots");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{});
    const web_threads = b.option(bool, "web_threads", "Enable worker threads in the web playground.") orelse false;
    const gpu_backend = b.option(Knots.GPUBackend, "gpu_backend", "GPU backend to compile into knots.") orelse defaultGpuBackend(target.result);

    const knots = b.dependency("knots", .{ .target = target, .optimize = optimize, .web_threads = web_threads, .gpu_backend = gpu_backend });

    const mod = b.addModule("playground", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "knots", .module = knots.module("knots") }},
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

    const exe = b.addExecutable(.{ .name = "playground", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the playground app");

    if (isBrowserWasmTarget(target.result)) {
        exe.entry = .disabled;

        Knots.installWeb(b, knots, exe_mod, exe, .{ .index_html = b.path("src/shell_wasm.html") });

        const serve = if (web_threads) blk: {
            const command = b.addSystemCommand(&.{"python3"});
            command.addFileArg(b.path("serve.py"));
            command.addArgs(&.{ "--port", "8000", "--directory", "zig-out/web" });
            break :blk command;
        } else b.addSystemCommand(&.{ "python3", "-m", "http.server", "8000", "--directory", "zig-out/web" });
        serve.step.dependOn(b.getInstallStep());
        run_step.dependOn(&serve.step);
    } else {
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);

        run_cmd.step.dependOn(b.getInstallStep());

        run_cmd.addPassthruArgs();

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

fn defaultGpuBackend(target: std.Target) Knots.GPUBackend {
    if (isBrowserWasmTarget(target)) return .webgpu;
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
