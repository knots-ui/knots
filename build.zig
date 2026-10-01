const std = @import("std");
const web_build = @import("web_build.zig");
const build_zon = @import("build.zig.zon");
const WaylandScanner = @import("wayland").Scanner;

pub const GPUBackend = @import("src/gpu/backend/root.zig").Backend;

pub const HMR = @import("HMR.zig");

/// Source files for knots' Vulkan UI-rendering shaders, written as comptime Zig and
/// compiled to SPIR-V at build time. Consumers driving their own Vulkan renderer for
/// knots' portable render packets can compile and reflect these without
/// reaching into knots' internal shader paths.
pub const VulkanShaderSource = enum {
    ui_primitives_vertex,
    ui_primitives_instance_vertex,
    ui_primitives_fragment,
    slug_vertex,
    slug_fragment,
};

fn vulkanUIShaderFileName(which: VulkanShaderSource) []const u8 {
    const dir = "src/gpu/backend/vulkan/shaders/";
    return switch (which) {
        .ui_primitives_vertex => dir ++ "ui_primitives_vertex.zig",
        .ui_primitives_instance_vertex => dir ++ "ui_primitives_instance_vertex.zig",
        .ui_primitives_fragment => dir ++ "ui_primitives_fragment.zig",
        .slug_vertex => dir ++ "slug_vertex.zig",
        .slug_fragment => dir ++ "slug_fragment.zig",
    };
}

pub fn vulkanUIShaderSource(knots_dep: *std.Build.Dependency, which: VulkanShaderSource) std.Build.LazyPath {
    return knots_dep.path(vulkanUIShaderFileName(which));
}

pub const web_bridge_export_symbol_names = web_build.bridge_export_symbol_names;

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
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    if (b.option(bool, "module_guest", "Build portable UI module dependencies.") orelse false) {
        buildModuleDependencies(b, target, optimize);
        return;
    }
    const browser_wasm = target.result.cpu.arch.isWasm();
    const web_threads = b.option(bool, "web_threads", "Enable worker threads in browser WebAssembly builds.") orelse true;
    if (browser_wasm) web_build.configureTarget(&target, web_threads);
    const accesskit_mod = if (browser_wasm) null else blk: {
        const dependency = b.dependency("accesskit", .{ .target = target, .optimize = optimize });
        break :blk dependency.module("accesskit");
    };

    const gpu_backend =
        b.option(GPUBackend, "gpu_backend", "GPU backend to compile into knots.") orelse
        defaultGpuBackend(target.result);

    const truetype_dep = b.dependency("TrueType", .{ .target = target, .optimize = optimize });

    const js_bridge_mod = if (browser_wasm)
        b.dependency("js_bridge", .{ .target = target, .optimize = optimize }).module("js-bridge")
    else
        null;

    if (js_bridge_mod) |m| b.modules.put(b.graph.arena, "js-bridge", m) catch @panic("OOM");
    if (browser_wasm) {
        b.addNamedLazyPath("web-host-js", b.path("src/web/host.js"));
        b.addNamedLazyPath("web-bridge-js", b.path("lib/js-bridge/src/runtime.js"));
        b.addNamedLazyPath("web-wasi-js", b.path("src/web/wasi.js"));
        if (web_threads) {
            b.addNamedLazyPath("web-worker-pool-js", b.path("src/web/worker-pool.js"));
            b.addNamedLazyPath("web-worker-js", b.path("src/web/worker.js"));
        }
    }

    const browser_exports_mod = if (browser_wasm) blk: {
        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/web/main.zig"),
            .imports = &.{.{ .name = "js-bridge", .module = js_bridge_mod.? }},
        });
        var web_config = b.addOptions();
        web_config.addOption(bool, "worker_concurrency_enabled", web_threads);
        mod.addOptions("web_config", web_config);
        break :blk mod;
    } else null;

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
            buildTool(vulkan.artifact("vulkan-zig-generator"));
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

    const render_types_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/render/types/root.zig"),
    });
    const gpu_mod = b.addModule("gpu", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/gpu/root.zig"),
    });
    gpu_mod.addImport("render_types", render_types_mod);
    gpu_impl_mod.addImport("gpu", gpu_mod);

    const input_mod = b.addModule("input", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/input/root.zig"),
    });

    var gpu_opts = b.addOptions();
    gpu_opts.addOption(GPUBackend, "backend", gpu_backend);
    gpu_mod.addOptions("config", gpu_opts);

    const window_drop_paths_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/window/drop_paths.zig"),
    });

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
                        .{ .name = "window_drop_paths", .module = window_drop_paths_mod },
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
                        .{ .name = "window_drop_paths", .module = window_drop_paths_mod },
                    },
                });
            },
            .linux => {
                const scanner = WaylandScanner.create(b, .{});
                buildTool(scanner.run.producer.?);
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
                        .{ .name = "window_drop_paths", .module = window_drop_paths_mod },
                    },
                });
                m.link_libc = true;
                m.linkSystemLibrary("wayland-client", .{});
                m.linkSystemLibrary("wayland-cursor", .{});
                m.linkSystemLibrary("xkbcommon", .{});
                break :blk m;
            },
            .freestanding, .wasi => {
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
                @panic("expected wasm arch for freestanding or wasi target");
            },
            else => |os| std.debug.panic("windowing implementation for {s} is not yet implemented", .{@tagName(os)}),
        }
    };

    const window_mod = b.addModule("window", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/window/root.zig"),
        .imports = &.{
            .{ .name = "gpu", .module = gpu_mod },
            .{ .name = "window_impl", .module = window_impl_mod },
            .{ .name = "window_drop_paths", .module = window_drop_paths_mod },
        },
    });
    window_impl_mod.addImport("window", window_mod);
    window_impl_mod.addImport("input", input_mod);
    window_mod.addImport("input", input_mod);

    const math_mod = b.addModule("math", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/math/root.zig"),
    });

    const signal_mod = b.addModule("signal", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/signal/root.zig"),
    });

    const text_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/text/root.zig"),
        .imports = &.{.{ .name = "TrueType", .module = truetype_dep.module("TrueType") }},
    });

    const render_mod = b.addModule("render", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/render/root.zig"),
        .imports = &.{
            .{ .name = "render_types", .module = render_types_mod },
            .{ .name = "math", .module = math_mod },
        },
    });

    const renderer_mod = b.addModule("renderer", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/renderer/root.zig"),
        .imports = &.{
            .{ .name = "gpu", .module = gpu_mod },
            .{ .name = "gpu_impl", .module = gpu_impl_mod },
            .{ .name = "math", .module = math_mod },
            .{ .name = "render", .module = render_mod },
        },
    });

    var render_shader_opts = b.addOptions();
    // Shader sources are always attached and gated by lazy analysis; only the
    // build-step SPIR-V blobs need a compile-time flag.
    render_shader_opts.addOption(bool, "has_spirv_shaders", gpu_backend == .vulkan);
    render_mod.addOptions("shader_config", render_shader_opts);

    addRenderShaderSources(b, render_mod);
    if (gpu_backend == .vulkan) {
        embedSpirV(b, optimize, render_mod, "primitives_vert_spv", b.path("src/gpu/backend/vulkan/shaders/ui_primitives_vertex.zig"));
        embedSpirV(b, optimize, render_mod, "primitives_instance_vert_spv", b.path("src/gpu/backend/vulkan/shaders/ui_primitives_instance_vertex.zig"));
        embedSpirV(b, optimize, render_mod, "slug_vert_spv", b.path("src/gpu/backend/vulkan/shaders/slug_vertex.zig"));
        embedSpirV(b, optimize, render_mod, "primitives_frag_spv", b.path("src/gpu/backend/vulkan/shaders/ui_primitives_fragment.zig"));
        embedSpirV(b, optimize, render_mod, "slug_frag_spv", b.path("src/gpu/backend/vulkan/shaders/slug_fragment.zig"));
        embedSpirV(b, optimize, render_mod, "backdrop_blur_vert_spv", b.path("src/gpu/backend/vulkan/shaders/backdrop_blur_vertex.zig"));
        embedSpirV(b, optimize, render_mod, "backdrop_blur_frag_spv", b.path("src/gpu/backend/vulkan/shaders/backdrop_blur_fragment.zig"));
        embedSpirV(b, optimize, render_mod, "backdrop_glass_vert_spv", b.path("src/gpu/backend/vulkan/shaders/backdrop_glass_vertex.zig"));
        embedSpirV(b, optimize, render_mod, "backdrop_glass_frag_spv", b.path("src/gpu/backend/vulkan/shaders/backdrop_glass_fragment.zig"));
    }

    const layout_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/layout/root.zig"),
        .imports = &.{.{ .name = "math", .module = math_mod }},
    });

    const style_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/style/root.zig"),
        .imports = &.{
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "math", .module = math_mod },
            .{ .name = "render_types", .module = render_types_mod },
        },
    });

    var state_bridge_config = b.addOptions();
    state_bridge_config.addOption(bool, "host_graph_enabled", true);
    const ui_mod = b.addModule("ui", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/ui/root.zig"),
        .imports = &.{
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "style", .module = style_mod },
            .{ .name = "text", .module = text_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "render_types", .module = render_types_mod },
            .{ .name = "render", .module = render_mod },
            .{ .name = "math", .module = math_mod },
            .{ .name = "signal", .module = signal_mod },
        },
    });
    const native_accessibility_mod = if (accesskit_mod) |accesskit| blk: {
        const native_accessibility = b.addModule("native_accessibility", .{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/NativeAccessibility.zig"),
            .imports = &.{
                .{ .name = "accesskit", .module = accesskit },
                .{ .name = "ui", .module = ui_mod },
                .{ .name = "gpu", .module = gpu_mod },
            },
        });
        window_mod.addImport("native_accessibility", native_accessibility);
        break :blk native_accessibility;
    } else null;
    ui_mod.addOptions("state_bridge_config", state_bridge_config);

    const portable = b.createModule(.{ .root_source_file = b.path("src/portable.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "ui", .module = ui_mod }} });
    const hmr_mod = b.addModule("hmr", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/hmr/root.zig"),
        .imports = &.{ .{ .name = "ui", .module = ui_mod }, .{ .name = "input", .module = input_mod }, .{ .name = "render", .module = render_mod }, .{ .name = "math", .module = math_mod }, .{ .name = "knots", .module = portable } },
    });
    hmr_mod.addImport("pack", b.dependency("pack", .{ .target = target, .optimize = optimize }).module("pack"));

    var debug_opts = b.addOptions();
    debug_opts.addOption([]const u8, "version", build_zon.version);

    const mod = b.addModule("knots", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "render", .module = render_mod },
            .{ .name = "renderer", .module = renderer_mod },
            .{ .name = "ui", .module = ui_mod },
            .{ .name = "window", .module = window_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "text", .module = text_mod },
            .{ .name = "gpu", .module = gpu_mod },
            .{ .name = "layout", .module = layout_mod },
            .{ .name = "math", .module = math_mod },
        },
    });
    mod.addOptions("debug_config", debug_opts);
    if (browser_wasm) mod.addImport("browser_exports", browser_exports_mod.?);
    if (accesskit_mod) |accesskit| mod.addImport("accesskit", accesskit);
    if (native_accessibility_mod) |native_accessibility| mod.addImport("native_accessibility", native_accessibility);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const native_accessibility_tests = if (native_accessibility_mod) |native_accessibility| b.addTest(.{ .root_module = native_accessibility }) else null;
    const layout_tests = b.addTest(.{ .root_module = layout_mod });
    const style_tests = b.addTest(.{ .root_module = style_mod });
    const ui_tests = b.addTest(.{ .root_module = ui_mod });
    const text_tests = b.addTest(.{ .root_module = text_mod });
    const math_tests = b.addTest(.{ .root_module = math_mod });
    const input_tests = b.addTest(.{ .root_module = input_mod });
    const signal_tests = b.addTest(.{ .root_module = signal_mod });
    const public_render_consumer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/public_render_consumer.zig"),
            .imports = &.{
                .{ .name = "render", .module = render_mod },
            },
        }),
    });

    const embedded_view_consumer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/embedded_view_consumer.zig"),
            .imports = &.{
                .{ .name = "knots-ui", .module = ui_mod },
                .{ .name = "knots-input", .module = input_mod },
                .{ .name = "knots-render", .module = render_mod },
                .{ .name = "knots-renderer", .module = renderer_mod },
            },
        }),
    });
    const render_tests = b.addTest(.{ .root_module = render_mod });
    const renderer_tests = b.addTest(.{ .root_module = renderer_mod });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hmr_mod })).step);
    test_step.dependOn(&b.addRunArtifact(render_tests).step);
    test_step.dependOn(&b.addRunArtifact(renderer_tests).step);
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    if (native_accessibility_tests) |tests| test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(layout_tests).step);
    test_step.dependOn(&b.addRunArtifact(style_tests).step);
    test_step.dependOn(&b.addRunArtifact(ui_tests).step);
    test_step.dependOn(&b.addRunArtifact(text_tests).step);
    test_step.dependOn(&b.addRunArtifact(math_tests).step);
    test_step.dependOn(&b.addRunArtifact(input_tests).step);
    test_step.dependOn(&b.addRunArtifact(signal_tests).step);
    test_step.dependOn(&b.addRunArtifact(public_render_consumer_tests).step);
    test_step.dependOn(&b.addRunArtifact(embedded_view_consumer_tests).step);

    if (!browser_wasm) {
        const snapshot_exe = b.addExecutable(.{
            .name = "knots-snapshots",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("tests/snapshots/main.zig"),
                .imports = &.{
                    .{ .name = "knots", .module = mod },
                    .{ .name = "gpu", .module = gpu_mod },
                    .{ .name = "ui", .module = ui_mod },
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
    b.getInstallStep().dependOn(addWebInstall(b, knots, root_module, exe, options));
}

pub fn addWebInstall(
    b: *std.Build,
    knots: *std.Build.Dependency,
    root_module: *std.Build.Module,
    exe: *std.Build.Step.Compile,
    options: WebInstallOptions,
) *std.Build.Step {
    const web_threads = knots.builder.named_lazy_paths.contains("web-worker-js");
    configureWebExecutable(b, knots, root_module, exe, options);
    const install = b.step(b.fmt("install-web-{s}-{s}", .{ options.dir, exe.name }), "Install a browser application");
    if (options.index_html) |index_html| {
        const install_index = b.addInstallFileWithDir(index_html, .{ .custom = options.dir }, options.index_name);
        install.dependOn(&install_index.step);
    }

    const install_host_js = b.addInstallFileWithDir(knots.namedLazyPath("web-host-js"), .{ .custom = options.dir }, options.host_js_name);
    const install_bridge_js = b.addInstallFileWithDir(knots.namedLazyPath("web-bridge-js"), .{ .custom = options.dir }, options.bridge_js_name);
    const install_wasm = b.addInstallFileWithDir(exe.getEmittedBin(), .{ .custom = options.dir }, options.wasm_name);

    install.dependOn(&install_host_js.step);
    install.dependOn(&install_bridge_js.step);
    const install_wasi_js = b.addInstallFileWithDir(knots.namedLazyPath("web-wasi-js"), .{ .custom = options.dir }, "knots-wasi.js");
    install.dependOn(&install_wasi_js.step);
    install.dependOn(&install_wasm.step);
    if (web_threads) {
        const install_worker_pool_js = b.addInstallFileWithDir(knots.namedLazyPath("web-worker-pool-js"), .{ .custom = options.dir }, "knots-worker-pool.js");
        const install_worker_js = b.addInstallFileWithDir(knots.namedLazyPath("web-worker-js"), .{ .custom = options.dir }, "knots-worker.js");
        install.dependOn(&install_worker_pool_js.step);
        install.dependOn(&install_worker_js.step);
    }
    return install;
}

pub fn configureWebExecutable(b: *std.Build, knots: *std.Build.Dependency, root_module: *std.Build.Module, exe: *std.Build.Step.Compile, options: WebInstallOptions) void {
    const web_threads = knots.builder.named_lazy_paths.contains("web-worker-js");
    web_build.configureExecutable(b, root_module, exe, web_threads, .{
        .start_symbol = options.start_symbol,
        .extra_export_symbol_names = options.extra_export_symbol_names,
    });
}

fn defaultGpuBackend(target: std.Target) GPUBackend {
    if (target.cpu.arch.isWasm()) return .webgpu;
    return switch (target.os.tag) {
        .macos => .webgpu,
        .windows, .linux => .vulkan,
        else => |os| std.debug.panic("windowing implementation for {s} is not yet implemented", .{@tagName(os)}),
    };
}

fn addRenderShaderSources(b: *std.Build, render_mod: *std.Build.Module) void {
    const webgpu_dir = "src/gpu/backend/webgpu/shaders/";
    const vulkan_dir = "src/gpu/backend/vulkan/shaders/";
    addShaderSource(b, render_mod, "primitives_wgsl", webgpu_dir ++ "ui_primitives.wgsl");
    addShaderSource(b, render_mod, "slug_wgsl", webgpu_dir ++ "slug.wgsl");
    addShaderSource(b, render_mod, "backdrop_wgsl", webgpu_dir ++ "backdrop.wgsl");
    addShaderSource(
        b,
        render_mod,
        "primitives_vertex_zig",
        vulkan_dir ++ "ui_primitives_vertex.zig",
    );
    addShaderSource(
        b,
        render_mod,
        "primitives_instance_vertex_zig",
        vulkan_dir ++ "ui_primitives_instance_vertex.zig",
    );
    addShaderSource(
        b,
        render_mod,
        "primitives_fragment_zig",
        vulkan_dir ++ "ui_primitives_fragment.zig",
    );
    addShaderSource(b, render_mod, "text_vertex_zig", vulkan_dir ++ "slug_vertex.zig");
    addShaderSource(b, render_mod, "text_fragment_zig", vulkan_dir ++ "slug_fragment.zig");
}

fn addShaderSource(b: *std.Build, module: *std.Build.Module, name: []const u8, path: []const u8) void {
    module.addAnonymousImport(name, .{ .root_source_file = b.path(path) });
}

fn embedSpirV(b: *std.Build, optimize: std.builtin.OptimizeMode, mod: *std.Build.Module, name: []const u8, path: std.Build.LazyPath) void {
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
            .imports = &.{.{ .name = "shader_common", .module = b.createModule(.{
                .target = vk_target,
                .optimize = optimize,
                .root_source_file = b.path("src/gpu/backend/vulkan/shaders/common.zig"),
            }) }},
        }),
        .use_llvm = false,
    });
    buildTool(spv);

    mod.addAnonymousImport(name, .{ .root_source_file = spv.getEmittedBin() });
}

/// Outside `--watch`, incremental compiles skip the build cache and would rebuild these tools every time.
fn buildTool(compile: *std.Build.Step.Compile) void {
    compile.incremental = false;
}

/// Portable modules have no window, GPU, JavaScript, or operating-system imports.
fn buildModuleDependencies(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const math = b.addModule("math", .{
        .root_source_file = b.path("src/math/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const signal = b.addModule("signal", .{
        .root_source_file = b.path("src/signal/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const input = b.addModule("input", .{
        .root_source_file = b.path("src/input/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const types = b.createModule(.{
        .root_source_file = b.path("src/render/types/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const layout = b.createModule(.{
        .root_source_file = b.path("src/layout/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "math", .module = math }},
    });
    const style = b.createModule(.{
        .root_source_file = b.path("src/style/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "layout", .module = layout },
            .{ .name = "math", .module = math },
            .{ .name = "render_types", .module = types },
        },
    });
    const truetype = b.dependency("TrueType", .{ .target = target, .optimize = optimize });
    const text = b.createModule(.{
        .root_source_file = b.path("src/text/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "TrueType", .module = truetype.module("TrueType") }},
    });
    const render = b.addModule("render", .{
        .root_source_file = b.path("src/render/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "math", .module = math },
            .{ .name = "render_types", .module = types },
        },
    });
    const shader_config = b.addOptions();
    shader_config.addOption(bool, "has_spirv_shaders", false);
    render.addOptions("shader_config", shader_config);
    addRenderShaderSources(b, render);
    var state_bridge_config = b.addOptions();
    state_bridge_config.addOption(bool, "host_graph_enabled", false);
    const ui = b.addModule("ui", .{
        .root_source_file = b.path("src/ui/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "math", .module = math },
            .{ .name = "input", .module = input },
            .{ .name = "render_types", .module = types },
            .{ .name = "layout", .module = layout },
            .{ .name = "style", .module = style },
            .{ .name = "render", .module = render },
            .{ .name = "text", .module = text },
            .{ .name = "signal", .module = signal },
        },
    });
    ui.addOptions("state_bridge_config", state_bridge_config);
    const portable = b.addModule("knots", .{
        .root_source_file = b.path("src/portable.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ui", .module = ui }},
    });
    const hmr = b.addModule("hmr", .{
        .root_source_file = b.path("src/hmr/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ui", .module = ui },
            .{ .name = "input", .module = input },
            .{ .name = "render", .module = render },
            .{ .name = "math", .module = math },
        },
    });
    hmr.addImport("knots", portable);
    hmr.addImport("pack", b.dependency("pack", .{ .target = target, .optimize = optimize }).module("pack"));
    if (!target.result.cpu.arch.isWasm()) {
        const tests = b.addTest(.{ .root_module = hmr });
        b.step("test", "Test the portable HMR boundary").dependOn(&b.addRunArtifact(tests).step);
    }
}
