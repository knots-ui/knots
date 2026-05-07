const std = @import("std");
const glfw = @import("glfw");

pub const GPUBackend = @import("src/gpu/backend/root.zig").Backend;

const SupportedBackends = struct {
    wgpu: bool,
    vulkan: bool,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gpu_backends =
        b.option([]const GPUBackend, "gpu_backends", "Which GPU backends to be available at runtime.") orelse
        &[_]GPUBackend{ .wgpu, .vulkan };

    const linux_display_server =
        b.option(glfw.LinuxBackend, "linux_display_server", "Which display server to use, .x11 and .wayland are supported. Defaults to .wayland.") orelse
        .wayland;

    var se = SupportedBackends{ .vulkan = false, .wgpu = false };
    for (gpu_backends) |be| {
        switch (be) {
            .vulkan => se.vulkan = true,
            .wgpu => se.wgpu = true,
        }
    }

    const glfw_dep = b.dependency("glfw", .{ .target = target, .optimize = optimize, .linux_backend = .wayland });
    const truetype_dep = b.dependency("TrueType", .{ .target = target, .optimize = optimize });

    const gpu_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/gpu/root.zig"),
    });

    const gpu_backend_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/gpu/backend/root.zig"),
        .imports = &.{.{ .name = "gpu", .module = gpu_mod }},
    });

    var gpu_backend_opts = b.addOptions();
    gpu_backend_opts.addOption(SupportedBackends, "gpu_backends", se);
    gpu_backend_mod.addOptions("config", gpu_backend_opts);

    for (gpu_backends) |gpu_backend| {
        const backend_mod = blk: switch (gpu_backend) {
            .wgpu => {
                const wgpu = b.dependency("wgpu", .{ .target = target, .optimize = optimize });
                break :blk b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .root_source_file = b.path("src/gpu/backend/wgpu/root.zig"),
                    .imports = &.{
                        .{ .name = "wgpu", .module = wgpu.module("wgpu") },
                        .{ .name = "gpu", .module = gpu_mod },
                    },
                });
            },
            .vulkan => {
                const vulkan = b.dependency("vulkan", .{
                    .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
                });
                const vk_backend = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .root_source_file = b.path("src/gpu/backend/vulkan/root.zig"),
                    .imports = &.{
                        .{ .name = "vk", .module = vulkan.module("vulkan-zig") },
                        .{ .name = "gpu", .module = gpu_mod },
                    },
                });
                embedZigSpirV(b, vk_backend, "ui_primitives_vertex_shader", b.path("src/gpu/backend/vulkan/shaders/ui_primitives_vertex.zig"));
                embedZigSpirV(b, vk_backend, "ui_primitives_instance_vertex_shader", b.path("src/gpu/backend/vulkan/shaders/ui_primitives_instance_vertex.zig"));
                embedZigSpirV(b, vk_backend, "slug_vertex_shader", b.path("src/gpu/backend/vulkan/shaders/slug_vertex.zig"));

                // TODO: Migrate to Zig and drop glslc as a dependency.
                // Will require a fix for https://codeberg.org/ziglang/zig/issues/35238
                // Among other things.
                embedSpirV(b, vk_backend, "ui_primitives_fragment_shader", b.path("src/gpu/backend/vulkan/shaders/ui_primitives.frag"));
                embedSpirV(b, vk_backend, "slug_fragment_shader", b.path("src/gpu/backend/vulkan/shaders/slug.frag"));

                break :blk vk_backend;
            },
        };
        gpu_backend_mod.addImport(b.fmt("gpu_{s}", .{@tagName(gpu_backend)}), backend_mod);
    }

    const window_impl_mod = blk: switch (target.result.os.tag) {
        .macos => {
            const objc_dep = b.dependency("zig_objc", .{ .target = target, .optimize = optimize });
            const m = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/window/backend/cocoa/root.zig"),
                .imports = &.{
                    .{ .name = "objc", .module = objc_dep.module("objc") },
                    .{ .name = "gpu", .module = gpu_mod },
                },
            });
            m.linkFramework("Cocoa", .{});
            m.linkFramework("QuartzCore", .{});
            break :blk m;
        },
        .windows => {
            const win32_dep = b.dependency("win32", .{});
            break :blk b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/window/backend/windows/root.zig"),
                .imports = &.{
                    .{ .name = "win32", .module = win32_dep.module("win32") },
                    .{ .name = "gpu", .module = gpu_mod },
                },
            });
        },
        .emscripten => b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/window/backend/emscripten/root.zig"),
            .imports = &.{.{ .name = "gpu", .module = gpu_mod }},
        }),
        .linux => {
            const m = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/window/backend/glfw/root.zig"),
                .imports = &.{
                    .{ .name = "glfw", .module = glfw_dep.module("glfw") },
                    .{ .name = "gpu", .module = gpu_mod },
                },
            });
            var glfw_opts = b.addOptions();
            glfw_opts.addOption(glfw.LinuxBackend, "linux_display_server", linux_display_server);
            m.addOptions("window_config", glfw_opts);
            break :blk m;
        },
        else => |os| std.debug.panic("windowing implementation for {s} is not yet implemented", .{@tagName(os)}),
    };

    const window_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/window/root.zig"),
        .imports = &.{
            .{ .name = "gpu", .module = gpu_mod },
            .{ .name = "window_impl", .module = window_impl_mod },
        },
    });
    window_impl_mod.addImport("window", window_mod);

    const text_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/text/root.zig"),
        .imports = &.{.{ .name = "TrueType", .module = truetype_dep.module("TrueType") }},
    });

    const render_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/render/root.zig"),
        .imports = &.{
            .{ .name = "gpu", .module = gpu_mod },
            .{ .name = "gpu_backend", .module = gpu_backend_mod },
            .{ .name = "text", .module = text_mod },
            .{ .name = "window", .module = window_mod },
        },
    });

    const layout_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/layout/root.zig"),
    });

    const ui_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/ui/root.zig"),
        .imports = &.{
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "text", .module = text_mod },
            .{ .name = "window", .module = window_mod },
            .{ .name = "gpu", .module = gpu_mod },
            .{ .name = "render", .module = render_mod },
        },
    });

    const component_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/component/root.zig"),
        .imports = &.{
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "ui", .module = ui_mod },
            .{ .name = "text", .module = text_mod },
        },
    });

    const control_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/control/root.zig"),
        .imports = &.{
            .{ .name = "ui", .module = ui_mod },
            .{ .name = "layout", .module = layout_mod },
        },
    });

    const animation_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/animation/root.zig"),
        .imports = &.{
            .{ .name = "layout", .module = layout_mod },
        },
    });

    const debug_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/debug/root.zig"),
        .imports = &.{
            .{ .name = "component", .module = component_mod },
            .{ .name = "ui", .module = ui_mod },
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "gpu_backend", .module = gpu_backend_mod },
            .{ .name = "gpu", .module = gpu_mod },
        },
    });

    const mod = b.addModule("knots", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "render", .module = render_mod },
            .{ .name = "ui", .module = ui_mod },
            .{ .name = "component", .module = component_mod },
            .{ .name = "control", .module = control_mod },
            .{ .name = "animation", .module = animation_mod },
            .{ .name = "window", .module = window_mod },
            .{ .name = "debug", .module = debug_mod },
        },
    });

    component_mod.addImport("knots", mod);
    control_mod.addImport("knots", mod);
    animation_mod.addImport("knots", mod);
    debug_mod.addImport("knots", mod);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const layout_tests = b.addTest(.{ .root_module = layout_mod });
    const ui_tests = b.addTest(.{ .root_module = ui_mod });
    const text_tests = b.addTest(.{ .root_module = text_mod });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_layout_tests = b.addRunArtifact(layout_tests);
    const run_ui_tests = b.addRunArtifact(ui_tests);
    const run_text_tests = b.addRunArtifact(text_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_layout_tests.step);
    test_step.dependOn(&run_ui_tests.step);
    test_step.dependOn(&run_text_tests.step);
}

fn embedSpirV(b: *std.Build, mod: *std.Build.Module, comptime name: []const u8, path: std.Build.LazyPath) void {
    const cmd = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.2", "-o" });
    const spv = cmd.addOutputFileArg(std.fmt.comptimePrint("{s}.spv", .{name}));
    cmd.addFileArg(path);
    mod.addAnonymousImport(name, .{ .root_source_file = spv });
}

// We should be using b.addObject with a resolved spir-v target
// but it doesn't work on windows due to a bug in the Zig build system.
fn embedZigSpirV(b: *std.Build, mod: *std.Build.Module, comptime name: []const u8, path: std.Build.LazyPath) void {
    const out_name = std.fmt.comptimePrint("{s}.spv", .{name});

    const cmd = b.addSystemCommand(&.{
        b.graph.zig_exe, "build-obj",
        "-fno-llvm",     "-ofmt=spirv",
        "-target",       "spirv32-vulkan",
        "-mcpu",         "vulkan_v1_2",
        "--name",        name,
    });
    cmd.addPrefixedFileArg("-Mroot=", path);
    const spv = cmd.addPrefixedOutputFileArg("-femit-bin=", out_name);

    mod.addAnonymousImport(name, .{ .root_source_file = spv });
}
