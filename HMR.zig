//!
//!     const dev = Knots.HMR.init(b, .{ .target = target });
//!     const exe = buildApp(b, dev.knots, dev.target);
//!     dev.addRunner(exe, b.step("dev", "Run with HMR"));
//!
//!
const std = @import("std");
const Knots = @import("build.zig");

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    gpu_backend: ?Knots.GPUBackend = null,
    threads: bool = false,
    build_file: ?std.Build.LazyPath = null,
    build_arguments: []const []const u8 = &.{},
    web: Knots.WebInstallOptions = .{},
    port: u16 = 8000,
};

pub const Dev = struct {
    b: *std.Build,
    knots: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .Debug,
    host: ?*std.Build.Dependency,
    options: Options,

    pub fn addRunner(dev: Dev, exe: *std.Build.Step.Compile, step: *std.Build.Step) void {
        const b = dev.b;
        exe.entry = .disabled;
        exe.use_llvm = false;
        if (dev.host == null) {
            var web = dev.options.web;
            web.extra_export_symbol_names = std.mem.concat(b.allocator, []const u8, &.{
                web.extra_export_symbol_names,
                &Knots.web_dev_export_symbol_names,
            }) catch @panic("OOM");
            Knots.configureWebExecutable(b, dev.knots, exe.root_module, exe, web);
        } else configureGuest(exe);
        if (b.option(bool, "knots_hmr_app_only", "Internal: used by the HMR runner") orelse false) {
            step.dependOn(&b.addInstallFileWithDir(exe.getEmittedBin(), .prefix, "hmr/staging/app.wasm").step);
            return;
        }

        const run = b.addRunArtifact(if (dev.host) |host| host.artifact("knots-dev-host") else server(b, dev.knots));
        run.addPrefixedFileArg("--zig=", .zig_exe);
        run.addPrefixedFileArg("--build-file=", dev.options.build_file orelse b.path("build.zig"));
        run.addArg(b.fmt("--step={s}", .{step.name}));
        run.addArg(b.fmt("--artifact-name={s}", .{exe.name}));
        run.addPrefixedDirectoryArg("--prefix=", b.graph.path(.install_prefix, ""));
        for (b.user_input_options.keys(), b.user_input_options.values()) |key, value| switch (value) {
            .flag => run.addArg(b.fmt("--build-arg=-D{s}", .{key})),
            .scalar => |scalar| run.addArg(b.fmt("--build-arg=-D{s}={s}", .{ key, scalar })),
            else => std.debug.panic("HMR dev runner: build option -D{s} is not a flag or scalar", .{key}),
        };
        for (dev.options.build_arguments) |argument| run.addArg(b.fmt("--build-arg={s}", .{argument}));
        if (dev.host == null) {
            var web = dev.options.web;
            web.dir = "hmr/web";
            run.step.dependOn(Knots.addWebHostInstall(b, dev.knots, web));
            run.addPrefixedDirectoryArg("--web-dir=", b.graph.path(.install_prefix, web.dir));
            run.addArg(b.fmt("--host-module=/{s}", .{web.host_js_name}));
            run.addArg(b.fmt("--port={d}", .{dev.options.port}));
        }
        step.dependOn(&run.step);
    }
};

pub fn init(b: *std.Build, options: Options) Dev {
    const gpu_backend = options.gpu_backend orelse Knots.defaultGpuBackend(options.target.result);
    if (options.target.result.cpu.arch.isWasm()) return .{
        .b = b,
        .knots = b.dependencyFromBuildZig(Knots, .{
            .target = options.target,
            .optimize = .Debug,
            .gpu_backend = gpu_backend,
            .dev = true,
            .web_threads = false,
        }),
        .target = options.target,
        .host = null,
        .options = options,
    };

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = if (options.threads) std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory, .bulk_memory_opt }) else .empty,
    });
    return .{
        .b = b,
        .knots = b.dependencyFromBuildZig(Knots, .{
            .target = target,
            .optimize = .Debug,
            .gpu_backend = gpu_backend,
            .platform = Knots.Platform.hosted,
        }),
        .target = target,
        .host = b.dependencyFromBuildZig(Knots, .{
            .target = options.target,
            .optimize = .Debug,
            .gpu_backend = gpu_backend,
        }),
        .options = options,
    };
}

fn server(b: *std.Build, knots: *std.Build.Dependency) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "knots-hmr-server",
        .root_module = b.createModule(.{
            .root_source_file = knots.builder.path("src/hmr/server.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    exe.root_module.addImport("celer", knots.builder.dependency("celer", .{
        .target = b.graph.host,
        .optimize = .fast,
    }).module("celer"));
    exe.root_module.addImport("watch", knots.builder.dependency("watch", .{
        .target = b.graph.host,
        .optimize = .fast,
    }).module("watch"));
    return exe;
}

fn configureGuest(guest: *std.Build.Step.Compile) void {
    guest.rdynamic = true;
    guest.export_memory = true;
    if (std.Target.wasm.featureSetHas(guest.root_module.resolved_target.?.result.cpu.features, .atomics)) {
        guest.import_memory = true;
        guest.shared_memory = true;
    }
    guest.initial_memory = 64 * 1024 * 1024;
    guest.max_memory = 1024 * 1024 * 1024;
    guest.stack_size = 16 * 1024 * 1024;
}
