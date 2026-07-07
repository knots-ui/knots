const std = @import("std");
const build_zon = @import("build.zig.zon");
const WaylandScanner = @import("wayland").Scanner;

pub const GPUBackend = @import("src/gpu/backend/root.zig").Backend;

pub const web_bridge_export_symbol_names = [_][]const u8{
    "js_bridge_alloc",
    "js_bridge_free",
    "js_bridge_dispatch",
    "js_bridge_pointer_size",
    "knots_last_error_len",
    "knots_last_error_copy",
};

pub const WebInstallOptions = struct {
    dir: []const u8 = "web",
    start_symbol: []const u8 = "main",
    host_js_name: []const u8 = "knots.js",
    bridge_js_name: []const u8 = "js-bridge.js",
    wasm_name: []const u8 = "app.wasm",
    index_html: ?std.Build.LazyPath = null,
    index_name: []const u8 = "index.html",
    extra_export_symbol_names: []const []const u8 = &.{},
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const browser_wasm = isBrowserWasmTarget(target.result);

    const gpu_backend =
        b.option(GPUBackend, "gpu_backend", "GPU backend to compile into knots.") orelse
        defaultGpuBackend(target.result);

    const truetype_dep = b.dependency("TrueType", .{ .target = target, .optimize = optimize });

    const js_bridge_mod = if (browser_wasm)
        b.dependency("js_bridge", .{ .target = target, .optimize = optimize }).module("js-bridge")
    else
        null;

    if (browser_wasm) {
        b.addNamedLazyPath("web-host-js", b.path("src/web/host.js"));
        b.addNamedLazyPath("web-bridge-js", b.path("lib/js-bridge/src/runtime.js"));
    }

    const browser_exports_mod = if (browser_wasm)
        b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/web/main.zig"),
            .imports = &.{.{ .name = "js-bridge", .module = js_bridge_mod.? }},
        })
    else
        null;

    const gpu_impl_mod = blk: switch (gpu_backend) {
        .webgpu => {
            const webgpu_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/gpu/backend/webgpu/root.zig"),
            });

            if (browser_wasm)
                webgpu_mod.addImport("js-bridge", js_bridge_mod.?)
            else {
                const wgpu = b.dependency("wgpu", .{ .target = target, .optimize = optimize });
                webgpu_mod.addImport("wgpu", wgpu.module("wgpu"));
            }

            break :blk webgpu_mod;
        },
        .vulkan => {
            const vulkan = b.dependency("vulkan", .{
                .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
            });
            break :blk b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/gpu/backend/vulkan/root.zig"),
                .imports = &.{
                    .{ .name = "vk", .module = vulkan.module("vulkan-zig") },
                },
            });
        },
    };

    const gpu_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/gpu/root.zig"),
    });
    gpu_impl_mod.addImport("gpu", gpu_mod);

    var gpu_opts = b.addOptions();
    gpu_opts.addOption(GPUBackend, "backend", gpu_backend);
    gpu_mod.addOptions("config", gpu_opts);

    const window_impl_mod = blk: {
        switch (target.result.os.tag) {
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
                m.linkFramework("CoreFoundation", .{});
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
            .linux => {
                const scanner = WaylandScanner.create(b, .{});
                scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
                scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
                scanner.generate("wl_compositor", 6);
                scanner.generate("wl_shm", 1);
                scanner.generate("wl_seat", 8);
                scanner.generate("wl_output", 4);
                scanner.generate("wl_data_device_manager", 3);
                scanner.generate("xdg_wm_base", 3);
                scanner.generate("zxdg_decoration_manager_v1", 1);

                const wayland_mod = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .root_source_file = scanner.result,
                });
                const m = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .root_source_file = b.path("src/window/backend/wayland/root.zig"),
                    .imports = &.{
                        .{ .name = "wayland", .module = wayland_mod },
                        .{ .name = "gpu", .module = gpu_mod },
                    },
                });
                m.link_libc = true;
                m.linkSystemLibrary("wayland-client", .{});
                m.linkSystemLibrary("wayland-cursor", .{});
                m.linkSystemLibrary("xkbcommon", .{});
                break :blk m;
            },
            .freestanding => {
                if (browser_wasm) {
                    break :blk b.createModule(.{
                        .target = target,
                        .optimize = optimize,
                        .root_source_file = b.path("src/window/backend/wasm/root.zig"),
                        .imports = &.{
                            .{ .name = "gpu", .module = gpu_mod },
                            .{ .name = "js-bridge", .module = js_bridge_mod.? },
                        },
                    });
                }
                @panic("expected wasm arch for freestanding target");
            },
            else => |os| std.debug.panic("windowing implementation for {s} is not yet implemented", .{@tagName(os)}),
        }
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

    const math_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/math/root.zig"),
    });

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
            .{ .name = "gpu_impl", .module = gpu_impl_mod },
            .{ .name = "text", .module = text_mod },
            .{ .name = "window", .module = window_mod },
            .{ .name = "math", .module = math_mod },
        },
    });

    var render_shader_opts = b.addOptions();
    render_shader_opts.addOption(bool, "has_wgsl_shaders", gpu_backend == .webgpu);
    render_shader_opts.addOption(bool, "has_spirv_shaders", gpu_backend == .vulkan);
    render_mod.addOptions("shader_config", render_shader_opts);

    if (gpu_backend == .webgpu) {
        render_mod.addAnonymousImport("primitives_wgsl", .{ .root_source_file = b.path("src/gpu/backend/webgpu/shaders/ui_primitives.wgsl") });
        render_mod.addAnonymousImport("slug_wgsl", .{ .root_source_file = b.path("src/gpu/backend/webgpu/shaders/slug.wgsl") });
    }
    if (gpu_backend == .vulkan) {
        embedZigSpirV(b, optimize, render_mod, "primitives_vert_spv", b.path("src/gpu/backend/vulkan/shaders/ui_primitives_vertex.zig"));
        embedZigSpirV(b, optimize, render_mod, "primitives_instance_vert_spv", b.path("src/gpu/backend/vulkan/shaders/ui_primitives_instance_vertex.zig"));
        embedZigSpirV(b, optimize, render_mod, "slug_vert_spv", b.path("src/gpu/backend/vulkan/shaders/slug_vertex.zig"));
        // TODO: Migrate to Zig and drop glslc as a dependency.
        // Will require a fix for https://codeberg.org/ziglang/zig/issues/35238
        // Among other things.
        embedSpirV(b, render_mod, "primitives_frag_spv", b.path("src/gpu/backend/vulkan/shaders/ui_primitives.frag"));
        embedSpirV(b, render_mod, "slug_frag_spv", b.path("src/gpu/backend/vulkan/shaders/slug.frag"));
    }

    const layout_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/layout/root.zig"),
        .imports = &.{.{ .name = "math", .module = math_mod }},
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
            .{ .name = "math", .module = math_mod },
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
            .{ .name = "math", .module = math_mod },
            .{ .name = "gpu", .module = gpu_mod },
            .{ .name = "render", .module = render_mod },
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
            .{ .name = "math", .module = math_mod },
        },
    });

    var debug_opts = b.addOptions();
    debug_opts.addOption([]const u8, "version", build_zon.version);
    const debug_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/debug/root.zig"),
        .imports = &.{
            .{ .name = "component", .module = component_mod },
            .{ .name = "ui", .module = ui_mod },
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "gpu", .module = gpu_mod },
        },
    });
    debug_mod.addOptions("debug_config", debug_opts);

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
    if (browser_wasm) mod.addImport("browser_exports", browser_exports_mod.?);

    component_mod.addImport("knots", mod);
    control_mod.addImport("knots", mod);
    animation_mod.addImport("knots", mod);
    debug_mod.addImport("knots", mod);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const layout_tests = b.addTest(.{ .root_module = layout_mod });
    const ui_tests = b.addTest(.{ .root_module = ui_mod });
    const text_tests = b.addTest(.{ .root_module = text_mod });
    const math_tests = b.addTest(.{ .root_module = math_mod });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_layout_tests = b.addRunArtifact(layout_tests);
    const run_ui_tests = b.addRunArtifact(ui_tests);
    const run_text_tests = b.addRunArtifact(text_tests);
    const run_math_tests = b.addRunArtifact(math_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_layout_tests.step);
    test_step.dependOn(&run_ui_tests.step);
    test_step.dependOn(&run_text_tests.step);
    test_step.dependOn(&run_math_tests.step);

    if (!isBrowserWasmTarget(target.result)) {
        const snapshot_exe = b.addExecutable(.{
            .name = "knots-snapshots",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("tests/snapshots/main.zig"),
                .imports = &.{
                    .{ .name = "knots", .module = mod },
                    .{ .name = "gpu", .module = gpu_mod },
                },
            }),
        });

        const run_snapshots = b.addRunArtifact(snapshot_exe);
        run_snapshots.addArg(@tagName(gpu_backend));
        const snapshots_step = b.step("snapshots", "Compare GPU rendering snapshots");
        snapshots_step.dependOn(&run_snapshots.step);

        const update_snapshots = b.addRunArtifact(snapshot_exe);
        update_snapshots.addArg(@tagName(gpu_backend));
        update_snapshots.addArg("--update");
        const update_snapshots_step = b.step("update-snapshots", "Regenerate GPU rendering snapshots");
        update_snapshots_step.dependOn(&update_snapshots.step);
    }
}

pub fn installWeb(
    b: *std.Build,
    knots: *std.Build.Dependency,
    root_module: *std.Build.Module,
    exe: *std.Build.Step.Compile,
    options: WebInstallOptions,
) void {
    const names = b.allocator.alloc([]const u8, 1 + web_bridge_export_symbol_names.len + options.extra_export_symbol_names.len) catch @panic("OOM");
    names[0] = options.start_symbol;
    for (web_bridge_export_symbol_names, 0..) |name, i| names[i + 1] = name;
    root_module.export_symbol_names = names;
    if (options.index_html) |index_html| {
        const install_index = b.addInstallFileWithDir(index_html, .{ .custom = options.dir }, options.index_name);
        b.getInstallStep().dependOn(&install_index.step);
    }

    const install_host_js = b.addInstallFileWithDir(knots.namedLazyPath("web-host-js"), .{ .custom = options.dir }, options.host_js_name);
    const install_bridge_js = b.addInstallFileWithDir(knots.namedLazyPath("web-bridge-js"), .{ .custom = options.dir }, options.bridge_js_name);
    const install_wasm = b.addInstallFileWithDir(exe.getEmittedBin(), .{ .custom = options.dir }, options.wasm_name);

    b.getInstallStep().dependOn(&install_host_js.step);
    b.getInstallStep().dependOn(&install_bridge_js.step);
    b.getInstallStep().dependOn(&install_wasm.step);
}

fn defaultGpuBackend(target: std.Target) GPUBackend {
    if (isBrowserWasmTarget(target)) return .webgpu;
    return switch (target.os.tag) {
        .macos => .webgpu,
        .windows, .linux => .vulkan,
        else => |os| std.debug.panic("windowing implementation for {s} is not yet implemented", .{@tagName(os)}),
    };
}

fn isBrowserWasmTarget(target: std.Target) bool {
    const is_wasm = switch (target.cpu.arch) {
        .wasm32, .wasm64 => true,
        else => false,
    };
    return is_wasm and target.os.tag == .freestanding;
}

fn embedSpirV(b: *std.Build, mod: *std.Build.Module, name: []const u8, path: std.Build.LazyPath) void {
    const cmd = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.3", "-o" });
    const spv = cmd.addOutputFileArg(b.fmt("{s}.spv", .{name}));
    cmd.addFileArg(path);
    mod.addAnonymousImport(name, .{ .root_source_file = spv });
}

fn embedZigSpirV(b: *std.Build, optimize: std.builtin.OptimizeMode, mod: *std.Build.Module, name: []const u8, path: std.Build.LazyPath) void {
    const vk_target = b.resolveTargetQuery(.{
        .cpu_arch = .spirv32,
        .os_tag = .vulkan,
        .cpu_model = .{ .explicit = &std.Target.spirv.cpu.vulkan_v1_2 },
    });

    const spv = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = vk_target,
            .optimize = optimize,
            .root_source_file = path,
        }),
    });

    mod.addAnonymousImport(name, .{ .root_source_file = spv.getEmittedBin() });
}
