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
pub const web_dev_export_symbol_names = web_build.dev_export_symbol_names;

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

pub const Platform = enum {
    native,
    browser,
    hosted,
};

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const platform = b.option(Platform, "platform", "Where the application runs: browser (default) or hosted, for a wasm32 target.") orelse
        if (target.result.cpu.arch.isWasm()) Platform.browser else .native;
    if ((platform == .native) == target.result.cpu.arch.isWasm())
        std.debug.panic("knots: the {t} platform needs a {s} target", .{ platform, if (platform == .native) "native" else "wasm32" });
    const dev_option = b.option(bool, "dev", "Build the application for `zig build dev` (see HMR.zig).") orelse false;
    const web_threads_option = b.option(bool, "web_threads", "Enable worker threads in browser WebAssembly builds.") orelse true;
    if (dev_option and platform == .native)
        std.debug.panic("knots: -Ddev needs a wasm32 target (see HMR.zig)", .{});
    const dev = dev_option or platform == .hosted;
    const web_threads = web_threads_option and platform == .browser;
    const wasm_threads = web_threads or
        (platform == .hosted and std.Target.wasm.featureSetHas(target.result.cpu.features, .atomics));
    if (platform != .native) web_build.configureWasmTarget(&target, wasm_threads);

    const accesskit_dep = if (platform == .native)
        b.dependency("accesskit", .{ .target = target, .optimize = optimize })
    else
        null;

    const gpu_backend =
        b.option(GPUBackend, "gpu_backend", "GPU backend to compile into knots.") orelse
        defaultGpuBackend(target.result);

    const truetype_dep = b.dependency("TrueType", .{ .target = target, .optimize = optimize });

    const js_bridge_mod = if (platform == .browser)
        b.dependency("js_bridge", .{ .target = target, .optimize = optimize }).module("js-bridge")
    else
        null;

    if (js_bridge_mod) |m| b.modules.put(b.graph.arena, "js-bridge", m) catch @panic("OOM");
    if (platform == .browser) {
        b.addNamedLazyPath("web-host-js", b.path("src/web/host.js"));
        b.addNamedLazyPath("web-bridge-js", b.path("lib/js-bridge/src/runtime.js"));
        b.addNamedLazyPath("web-wasi-js", b.path("src/web/wasi.js"));
        if (web_threads) {
            b.addNamedLazyPath("web-worker-pool-js", b.path("src/web/worker-pool.js"));
            b.addNamedLazyPath("web-worker-js", b.path("src/web/worker.js"));
        }
    }

    const wire_mod = b.createModule(.{ .target = target, .optimize = optimize, .root_source_file = b.path("src/wire.zig") });
    const hosted_imports_mod = if (platform == .hosted) b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/hosted/guest/imports.zig"),
    }) else null;

    const wasm_threads_mod = if (wasm_threads) b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/wasm/threads.zig"),
        .imports = &.{.{ .name = "worker_host", .module = hosted_imports_mod orelse b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/web/worker_host.zig"),
            .imports = &.{.{ .name = "js-bridge", .module = js_bridge_mod.? }},
        }) }},
    }) else null;

    const platform_impl_mod = switch (platform) {
        .native => null,
        .browser => blk: {
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
        },
        .hosted => b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/hosted/guest/root.zig"),
            .imports = &.{
                .{ .name = "wire", .module = wire_mod },
                .{ .name = "imports", .module = hosted_imports_mod.? },
            },
        }),
    };
    if (wasm_threads_mod) |threads| platform_impl_mod.?.addImport("wasm_threads", threads);
    const wasm_buffer_mod = if (platform_impl_mod) |platform_impl| b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/wasm/buffer.zig"),
        .imports = &.{.{ .name = "platform_impl", .module = platform_impl }},
    }) else null;

    const gpu_impl_mod = if (platform == .hosted) b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/gpu/backend/hosted/root.zig"),
        .imports = &.{.{ .name = "hosted", .module = platform_impl_mod.? }},
    }) else blk: switch (gpu_backend) {
        .webgpu => {
            const webgpu_mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/gpu/backend/webgpu/root.zig"),
            });

            if (platform == .browser)
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
        if (platform == .hosted) break :blk b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/window/backend/hosted/root.zig"),
            .imports = &.{
                .{ .name = "gpu", .module = gpu_mod },
                .{ .name = "wire", .module = wire_mod },
                .{ .name = "hosted", .module = platform_impl_mod.? },
                .{ .name = "wasm_buffer", .module = wasm_buffer_mod.? },
                .{ .name = "window_drop_paths", .module = window_drop_paths_mod },
            },
        });
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
                if (platform == .browser) {
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

    const abi_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/hosted/abi.zig"),
        .imports = &.{
            .{ .name = "input", .module = input_mod },
            .{ .name = "gpu", .module = gpu_mod },
            .{ .name = "window", .module = window_mod },
        },
    });
    if (platform == .hosted) platform_impl_mod.?.addImport("abi", abi_mod);

    const math_mod = b.addModule("math", .{
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
            .{ .name = "wire", .module = wire_mod },
        },
    });
    const native_accessibility_mod = if (accesskit_dep) |accesskit| blk: {
        const native_accessibility = b.addModule("native_accessibility", .{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/NativeAccessibility.zig"),
            .imports = &.{
                .{ .name = "accesskit", .module = accesskit.module("accesskit") },
                .{ .name = "ui", .module = ui_mod },
                .{ .name = "gpu", .module = gpu_mod },
            },
        });
        window_mod.addImport("native_accessibility", native_accessibility);
        break :blk native_accessibility;
    } else null;

    const hmr_tests_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/hmr/root.zig"),
    });

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
    const platform_opts = b.addOptions();
    platform_opts.addOption(Platform, "platform", platform);
    platform_opts.addOption(bool, "dev", dev);
    mod.addOptions("platform_config", platform_opts);
    if (dev) {
        mod.addImport("wire", wire_mod);
        mod.addImport("abi", abi_mod);
        mod.addImport("wasm_buffer", wasm_buffer_mod.?);
    }
    if (platform_impl_mod) |platform_impl| mod.addImport("platform_impl", platform_impl);
    if (accesskit_dep) |accesskit| mod.addImport("accesskit", accesskit.module("accesskit"));
    if (native_accessibility_mod) |native_accessibility| mod.addImport("native_accessibility", native_accessibility);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const layout_tests = b.addTest(.{ .root_module = layout_mod });
    const style_tests = b.addTest(.{ .root_module = style_mod });
    const ui_tests = b.addTest(.{ .root_module = ui_mod });
    const text_tests = b.addTest(.{ .root_module = text_mod });
    const math_tests = b.addTest(.{ .root_module = math_mod });
    const input_tests = b.addTest(.{ .root_module = input_mod });
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
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hmr_tests_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = wire_mod })).step);
    test_step.dependOn(&b.addRunArtifact(render_tests).step);
    test_step.dependOn(&b.addRunArtifact(renderer_tests).step);
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    if (platform == .native and gpu_backend == .vulkan) {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = gpu_impl_mod })).step);
    }
    if (native_accessibility_mod) |native_accessibility| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = native_accessibility })).step);
    }
    test_step.dependOn(&b.addRunArtifact(layout_tests).step);
    test_step.dependOn(&b.addRunArtifact(style_tests).step);
    test_step.dependOn(&b.addRunArtifact(ui_tests).step);
    test_step.dependOn(&b.addRunArtifact(text_tests).step);
    test_step.dependOn(&b.addRunArtifact(math_tests).step);
    test_step.dependOn(&b.addRunArtifact(input_tests).step);
    test_step.dependOn(&b.addRunArtifact(public_render_consumer_tests).step);
    test_step.dependOn(&b.addRunArtifact(embedded_view_consumer_tests).step);
    if (platform == .native) {
        const dev_host_module_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("src/hosted/host/module.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(dev_host_module_tests).step);
    }
    // Only the dev host's knots declares this, so other builds skip wasmtime.
    const dev_host_option = b.option(bool, "dev_host", "Declare the HMR dev host's module (see HMR.zig).") orelse false;
    if (platform == .native and dev_host_option) {
        const watch = b.dependency("watch", .{ .target = target, .optimize = .ReleaseFast }).module("watch");
        const hmr_builder = b.createModule(.{
            .root_source_file = b.path("src/hmr/Builder.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "watch", .module = watch }},
        });
        const host_mod = b.addModule("knots_dev_host", .{
            .root_source_file = b.path("src/hosted/host/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "window", .module = window_mod },
                .{ .name = "input", .module = input_mod },
                .{ .name = "gpu", .module = gpu_mod },
                .{ .name = "gpu_impl", .module = gpu_impl_mod },
                .{ .name = "wire", .module = wire_mod },
                .{ .name = "abi", .module = abi_mod },
                .{ .name = "hmr_builder", .module = hmr_builder },
            },
        });
        if (b.lazyDependency("wasmtime", .{ .target = target, .optimize = .debug })) |wasmtime|
            host_mod.addImport("wasmtime", wasmtime.module("wasmtime"));
        if (target.result.os.tag == .macos)
            host_mod.addImport("objc", b.dependency("zig_objc", .{ .target = target, .optimize = optimize }).module("objc"));
    }

    if (platform == .native) {
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
    configureWebExecutable(b, knots, root_module, exe, options);
    const install = b.step(b.fmt("install-web-{s}-{s}", .{ options.dir, exe.name }), "Install a browser application");
    install.dependOn(addWebHostInstall(b, knots, options));
    const install_wasm = b.addInstallFileWithDir(exe.getEmittedBin(), .{ .custom = options.dir }, options.wasm_name);
    install.dependOn(&install_wasm.step);
    return install;
}

pub fn addWebHostInstall(b: *std.Build, knots: *std.Build.Dependency, options: WebInstallOptions) *std.Build.Step {
    const web_threads = knots.builder.named_lazy_paths.contains("web-worker-js");
    const install = b.step(b.fmt("install-web-host-{s}", .{options.dir}), "Install the page of a browser application");
    if (options.index_html) |index_html| {
        const install_index = b.addInstallFileWithDir(index_html, .{ .custom = options.dir }, options.index_name);
        install.dependOn(&install_index.step);
    }

    const install_host_js = b.addInstallFileWithDir(knots.namedLazyPath("web-host-js"), .{ .custom = options.dir }, options.host_js_name);
    const install_bridge_js = b.addInstallFileWithDir(knots.namedLazyPath("web-bridge-js"), .{ .custom = options.dir }, options.bridge_js_name);
    install.dependOn(&install_host_js.step);
    install.dependOn(&install_bridge_js.step);
    const install_wasi_js = b.addInstallFileWithDir(knots.namedLazyPath("web-wasi-js"), .{ .custom = options.dir }, "knots-wasi.js");
    install.dependOn(&install_wasi_js.step);
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

pub fn defaultGpuBackend(target: std.Target) GPUBackend {
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
