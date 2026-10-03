const std = @import("std");
const Discovery = @import("src/hmr/Discovery.zig");
const web_build = @import("web_build.zig");

pub const Options = struct {
    knots: *std.Build.Dependency,
    roots: []const std.Build.LazyPath,
    watch_roots: []const std.Build.LazyPath = &.{},
};

pub const DevOptions = struct {
    build_file: ?std.Build.LazyPath = null,
    build_arguments: []const []const u8 = &.{},
    application_arguments: []const []const u8 = &.{},
    web_dir: []const u8 = "web",
    web_host_js_name: []const u8 = "knots.js",
    port: u16 = 8000,
    web_wasm_name: []const u8 = "app.wasm",
};

builder: *std.Build,
executable: *std.Build.Step.Compile,
options: Options,
artifacts: *std.Build.Step,
runtime: *std.Build.Module,
configuration: std.Build.LazyPath,
native_registry: *std.Build.Module,
snapshot_step: *std.Build.Step,

const HMR = @This();

pub fn init(b: *std.Build, executable: *std.Build.Step.Compile, options: Options) HMR {
    const roots = b.allocator.alloc([]const u8, options.roots.len) catch @panic("OOM");
    // Discovery affects graph shape, including files that did not exist last run.
    b.graph.poisonCache();

    for (options.roots, roots) |root, *path| path.* = switch (root) {
        .src_path => |source| source.owner.root.joinString(b.allocator, source.sub_path) catch @panic("OOM"),
        .dependency => |dependency| dependency.dependency.builder.root.joinString(b.allocator, dependency.sub_path) catch @panic("OOM"),
        .cwd_relative => |source| source,
        else => @panic("HMR roots must be existing source directories"),
    };

    for (roots) |*root|
        root.* = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, root.*, b.allocator) catch
            @panic("HMR root does not exist");

    const discovered = Discovery.scan(b.allocator, b.graph.io, roots) catch |err|
        std.debug.panic("HMR discovery: {s}", .{@errorName(err)});

    // Watch all inputs under source roots; callers can add external asset directories.
    const watch_roots = b.allocator.alloc([]const u8, roots.len + options.watch_roots.len) catch @panic("OOM");
    for (roots, watch_roots[0..roots.len]) |root, *watch|
        watch.* = root;

    for (options.watch_roots, watch_roots[roots.len..]) |root, *watch| {
        const path = switch (root) {
            .src_path => |source| source.owner.root.joinString(b.allocator, source.sub_path) catch @panic("OOM"),
            .dependency => |dependency| dependency.dependency.builder.root.joinString(b.allocator, dependency.sub_path) catch @panic("OOM"),
            .cwd_relative => |source| source,
            else => @panic("HMR watch roots must be existing source directories"),
        };
        watch.* = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, path, b.allocator) catch @panic("HMR watch root does not exist");
    }
    const inputs = Discovery.pathsInRoots(b.allocator, b.graph.io, watch_roots) catch @panic("HMR input enumeration failed");

    var common = watch_roots[0];
    for (watch_roots) |root| {
        while (true) {
            const relative = std.fs.path.relativeAlloc(b.allocator, common, null, common, root) catch @panic("OOM");
            if (!std.mem.eql(u8, relative, "..")) {
                if (!std.mem.startsWith(u8, relative, "../")) {
                    if (!std.mem.startsWith(u8, relative, "..\\")) break;
                }
            }
            common = std.fs.path.dirname(common) orelse @panic("HMR roots must share a filesystem root");
        }
    }

    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const guest = b.dependencyFromBuildZig(@import("build.zig"), .{
        .target = target,
        .optimize = .debug,
        .module_guest = true,
    });
    const guest_hmr = guest.module("hmr");
    const native_knots = b.createModule(.{
        .root_source_file = options.knots.path("src/portable.zig"),
        .target = executable.root_module.resolved_target.?,
        .optimize = executable.root_module.optimize.?,
        .imports = &.{.{ .name = "ui", .module = options.knots.module("ui") }},
    });
    const artifacts = b.step("knots-hmr-modules", "Build discovered HMR modules without rebuilding the host");
    const files = b.addWriteFiles();
    // Preserve input paths across builds. Content-addressing the entire source
    // tree changes every module's compiler identity on any single-file edit.
    const snapshot = b.graph.path(.local_cache, b.fmt("knots-modules/{x}", .{std.hash.Wyhash.hash(0, common)}));

    const Copy = struct { source: []const u8, target: []const u8 };
    const Generated = struct { target: []const u8, contents: []const u8 };

    var copies: std.ArrayList(Copy) = .empty;
    var generated: std.ArrayList(Generated) = .empty;
    for (inputs) |path| {
        const relative = std.fs.path.relativeAlloc(b.allocator, common, null, common, path) catch @panic("OOM");
        copies.append(b.allocator, .{ .source = path, .target = b.fmt("tree/{s}", .{relative}) }) catch @panic("OOM");
    }

    const snapshot_exe = b.addExecutable(.{ .name = "knots-module-snapshot", .root_module = b.createModule(.{
        .root_source_file = options.knots.path("src/hmr/Snapshot.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    const snapshot_run = b.addRunArtifact(snapshot_exe);
    snapshot_run.has_side_effects = true;

    const native_registry = b.createModule(.{ .target = executable.root_module.resolved_target.?, .optimize = executable.root_module.optimize.? });
    native_registry.addImport("knots", native_knots);
    native_registry.addImport("knots-ui", options.knots.module("ui"));

    var registry_source: std.Io.Writer.Allocating = .init(b.allocator);
    registry_source.writer.writeAll("const knots = @import(\"knots\");\nconst Context = knots.Frame;\npub const Entry = struct { id: []const u8, path: []const u8, source: []const u8, main: *const fn (*Context) anyerror!void, cleanup: ?*const fn () void };\npub const entries = entries: { @setEvalBranchQuota(100000); var result: []const Entry = &.{};\n") catch @panic("OOM");
    for (discovered) |file| {
        const relative = std.fs.path.relativeAlloc(b.allocator, common, null, common, file.path) catch @panic("OOM");
        const import_path = b.fmt("tree/{s}", .{relative});
        std.mem.replaceScalar(u8, import_path, '\\', '/');
        const quoted_path = std.json.Stringify.valueAlloc(b.allocator, import_path, .{}) catch @panic("OOM");
        const quoted_id = std.json.Stringify.valueAlloc(b.allocator, file.id, .{}) catch @panic("OOM");
        const entry_name = b.fmt("entry-{x}.zig", .{std.hash.Wyhash.hash(0, file.id)});
        generated.append(b.allocator, .{ .target = entry_name, .contents = b.fmt("pub const source = @import({s});\npub const text = @embedFile({s});\n", .{ quoted_path, quoted_path }) }) catch @panic("OOM");
        const entry = snapshot.path(b, entry_name);
        registry_source.writer.print("if (@hasDecl(@import({s}), \"main\")) result = result ++ [_]Entry{{.{{ .id = {s}, .path = {s}, .source = @embedFile({s}), .main = &@import({s}).main, .cleanup = if (@hasDecl(@import({s}), \"deinit\")) &@import({s}).deinit else null }}}};\n", .{ quoted_path, quoted_id, quoted_path, quoted_path, quoted_path, quoted_path, quoted_path }) catch @panic("OOM");
        const source = b.createModule(.{
            .root_source_file = entry,
            .target = target,
            .optimize = .debug,
            .imports = &.{ .{ .name = "knots", .module = guest.module("knots") }, .{ .name = "knots-ui", .module = guest.module("ui") } },
        });
        const adapter = b.createModule(.{
            .root_source_file = options.knots.path("src/hmr/guest.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "hmr", .module = guest_hmr },
                .{ .name = "hmr_source", .module = source },
                .{ .name = "ui", .module = guest.module("ui") },
            },
        });
        adapter.strip = true;
        const wasm = b.addExecutable(.{ .name = std.fs.path.basename(file.id), .root_module = adapter });
        wasm.step.dependOn(&snapshot_run.step);
        wasm.entry = .disabled;
        wasm.rdynamic = true;
        wasm.export_memory = true;
        wasm.initial_memory = 16 * 1024 * 1024;
        wasm.max_memory = 256 * 1024 * 1024;
        const staged_path = b.fmt("hmr/staging/{s}.wasm", .{file.id});
        const install = b.addInstallFileWithDir(wasm.getEmittedBin(), .prefix, staged_path);
        artifacts.dependOn(&install.step);
    }

    registry_source.writer.writeAll("if (result.len > 128) @compileError(\"Too many HMR modules\"); break :entries result; };\n") catch @panic("OOM");
    generated.append(b.allocator, .{ .target = "native_registry.zig", .contents = registry_source.written() }) catch @panic("OOM");
    native_registry.root_source_file = snapshot.path(b, "native_registry.zig");
    executable.step.dependOn(&snapshot_run.step);

    const snapshot_config = files.add("snapshot.json", std.json.Stringify.valueAlloc(
        b.allocator,
        .{ .copies = copies.items, .generated = generated.items },
        .{},
    ) catch @panic("OOM"));
    snapshot_run.addFileArg(snapshot_config);
    snapshot_run.addDirectoryArg(snapshot);

    const host_target = executable.root_module.resolved_target.?;
    const wasmtime = if (host_target.result.cpu.arch.isWasm()) null else options.knots.builder.lazyDependency("wasmtime", .{ .target = host_target, .optimize = .debug });
    const runtime = b.createModule(.{
        .root_source_file = options.knots.path("src/hmr/Runtime.zig"),
        .target = host_target,
        .optimize = executable.root_module.optimize.?,
        .imports = &.{
            .{ .name = "hmr", .module = options.knots.module("hmr") },
            .{ .name = "ui", .module = options.knots.module("ui") },
            .{ .name = "input", .module = options.knots.module("input") },
            .{ .name = "math", .module = options.knots.module("math") },
        },
    });
    if (wasmtime) |dependency|
        runtime.addImport("wasmtime", dependency.module("wasmtime"));

    const runtime_options = b.addOptions();
    runtime_options.addOption(bool, "reloadable", true);
    runtime.addOptions("runtime_options", runtime_options);

    const fixture_source = b.createModule(.{
        .root_source_file = options.knots.path("src/hmr/fixtures/counter.zig"),
        .target = target,
        .optimize = .debug,
        .imports = &.{.{ .name = "knots", .module = guest.module("knots") }},
    });

    const fixture = b.addExecutable(.{ .name = "module-counter-fixture", .root_module = b.createModule(.{
        .root_source_file = options.knots.path("src/hmr/guest.zig"),
        .target = target,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "hmr", .module = guest_hmr },
            .{ .name = "hmr_source", .module = fixture_source },
            .{ .name = "ui", .module = guest.module("ui") },
        },
    }) });
    fixture.entry = .disabled;
    fixture.rdynamic = true;
    fixture.export_memory = true;
    fixture.initial_memory = 16 * 1024 * 1024;
    fixture.max_memory = 256 * 1024 * 1024;

    const test_module = b.createModule(.{
        .root_source_file = options.knots.path("src/hmr/Runtime.zig"),
        .target = host_target,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "hmr", .module = options.knots.module("hmr") },
            .{ .name = "ui", .module = options.knots.module("ui") },
            .{ .name = "input", .module = options.knots.module("input") },
            .{ .name = "math", .module = options.knots.module("math") },
        },
    });
    if (wasmtime) |dependency|
        test_module.addImport("wasmtime", dependency.module("wasmtime"));

    test_module.addOptions("runtime_options", runtime_options);
    test_module.addAnonymousImport("fixture_wasm", .{ .root_source_file = fixture.getEmittedBin() });

    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    if (wasmtime) |dependency| if (dependency.builder.named_lazy_paths.get("dll_dir")) |dir| run_tests.setCwd(dir);
    b.step("module-test", "Test isolated UI execution and independent replacement").dependOn(&run_tests.step);

    const configuration = files.add("server.json", std.json.Stringify.valueAlloc(b.allocator, .{
        .roots = roots,
        .watch_roots = watch_roots,
        .watch_root = common,
    }, .{}) catch @panic("OOM"));

    const result: HMR = .{ .builder = b, .executable = executable, .options = options, .artifacts = artifacts, .runtime = runtime, .configuration = configuration, .native_registry = native_registry, .snapshot_step = &snapshot_run.step };
    result.injectRuntime(executable, runtime);
    return result;
}

/// Attach compiled-in modules to a standalone native executable.
pub fn attachNative(self: *const HMR, executable: *std.Build.Step.Compile) void {
    const runtime = self.builder.createModule(.{
        .root_source_file = self.options.knots.path("src/hmr/Runtime.zig"),
        .target = executable.root_module.resolved_target.?,
        .optimize = executable.root_module.optimize.?,
        .imports = &.{
            .{ .name = "hmr", .module = self.options.knots.module("hmr") },
            .{ .name = "ui", .module = self.options.knots.module("ui") },
            .{ .name = "input", .module = self.options.knots.module("input") },
            .{ .name = "math", .module = self.options.knots.module("math") },
            .{ .name = "native_registry", .module = self.native_registry },
        },
    });
    const options = self.builder.addOptions();
    options.addOption(bool, "reloadable", false);
    runtime.addOptions("runtime_options", options);
    executable.step.dependOn(self.snapshot_step);
    self.injectRuntime(executable, runtime);
}

fn injectRuntime(self: *const HMR, executable: *std.Build.Step.Compile, runtime: *std.Build.Module) void {
    const facade = self.builder.createModule(.{
        .root_source_file = self.options.knots.path("src/modules.zig"),
        .target = executable.root_module.resolved_target.?,
        .optimize = executable.root_module.optimize.?,
        .imports = &.{ .{ .name = "knots", .module = self.options.knots.module("knots") }, .{ .name = "modules", .module = runtime } },
    });

    // Inject the same runtime into consumer modules such as playground's host library.
    var pending: std.ArrayList(*std.Build.Module) = .empty;
    pending.append(self.builder.allocator, executable.root_module) catch
        @panic("OOM");

    var next: u32 = 0;
    while (next < pending.items.len) : (next += 1) {
        if (next == 128) @panic("HMR host import graph exceeds 128 modules");
        const module = pending.items[next];
        for (module.import_table.values()) |imported| {
            if (imported == runtime) continue;
            if (std.mem.indexOfScalar(*std.Build.Module, pending.items, imported) != null) continue;
            // Only modify modules belonging to this consumer's builder.
            if (imported.owner != self.builder) continue;
            pending.append(self.builder.allocator, imported) catch @panic("OOM");
        }
        if (module.import_table.contains("knots")) module.addImport("knots", facade);
    }
}

pub fn addDevRunner(self: *const HMR, options: DevOptions) *std.Build.Step.Run {
    const b = self.builder;
    if (options.port == 0) @panic("HMR server port must be nonzero");

    const server = b.addExecutable(.{
        .name = "knots-hmr-server",
        .root_module = b.createModule(.{
            .root_source_file = self.options.knots.path("src/hmr/Server.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const browser_host = self.executable.root_module.resolved_target.?.result.cpu.arch.isWasm();
    if (browser_host) {
        const web_threads = self.options.knots.builder.named_lazy_paths.contains("web-worker-js");
        web_build.configureExecutable(b, self.executable.root_module, self.executable, web_threads, .{});
    }
    server.root_module.addImport("celer", self.options.knots.builder.dependency("celer", .{
        .target = b.graph.host,
        .optimize = .debug,
    }).module("celer"));
    server.root_module.addImport("watch", self.options.knots.builder.dependency("watch", .{
        .target = b.graph.host,
        .optimize = .debug,
    }).module("watch"));

    const check = b.step("hmr-check", "Compile HMR host, server and module artifacts");
    check.dependOn(&server.step);
    check.dependOn(&self.executable.step);
    check.dependOn(self.artifacts);

    const run = b.addRunArtifact(server);
    if (browser_host) {
        if (options.web_dir.len == 0) @panic("HMR browser web directory must not be empty");
        if (options.web_host_js_name.len == 0) @panic("HMR browser host JavaScript name must not be empty");
        if (options.web_wasm_name.len == 0) @panic("HMR browser WebAssembly name must not be empty");
        const install_wasm = b.addInstallFileWithDir(self.executable.getEmittedBin(), .{ .custom = options.web_dir }, options.web_wasm_name);
        install_wasm.step.dependOn(b.getInstallStep());
        run.step.dependOn(&install_wasm.step);
    }
    run.addFileArg(self.configuration);
    run.addFileArg(.zig_exe);
    run.addFileArg(options.build_file orelse b.path("build.zig"));
    run.addDirectoryArg(b.graph.path(.install_prefix, ""));
    run.addArg(b.fmt("{d}", .{options.port}));
    run.addArg(if (browser_host) "browser" else "native");

    for (b.user_input_options.keys(), b.user_input_options.values()) |key, value| {
        switch (value) {
            .flag => run.addArg(b.fmt("-D{s}", .{key})),
            .scalar => |scalar| run.addArg(b.fmt("-D{s}={s}", .{ key, scalar })),
            else => @panic("HMR accepts scalar build options"),
        }
    }

    run.addArgs(options.build_arguments);
    run.addArg("--");
    if (browser_host) {
        run.addDirectoryArg(b.graph.path(.install_prefix, options.web_dir));
        run.addArg(b.fmt("/{s}", .{options.web_host_js_name}));
    } else {
        run.addFileArg(self.executable.getEmittedBin());
        run.addArgs(options.application_arguments);
    }
    run.addPassthruArgs();

    return run;
}
