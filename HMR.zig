//! Hot module reloading for a knots application. `init` walks the files the
//! executable reaches from its root module (see src/hmr/graph.zig). Each
//! reachable file that can run in isolation and declares
//! `pub fn main(frame: *knots.Frame) !void` becomes a module. The host
//! renders one with `Modules.indexOf(@import("file.zig"))`.
//!
//! Call `init` after the executable has all of its imports.
const std = @import("std");
const graph = @import("src/hmr/graph.zig");
const snapshot = @import("src/hmr/snapshot.zig");
const web_build = @import("web_build.zig");

pub const Options = struct {
    knots: *std.Build.Dependency,
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

/// The portable modules that HMR modules compile against.
pub const Guest = struct { knots: *std.Build.Module, ui: *std.Build.Module, hmr: *std.Build.Module };

/// What the runtime knows at compile time, so that the host can only
/// reference modules that exist.
const Catalog = struct {
    module_ids: []const []const u8 = &.{},
    rejected_ids: []const []const u8 = &.{},
    rejected_reasons: []const []const u8 = &.{},
};

builder: *std.Build,
executable: *std.Build.Step.Compile,
knots: *std.Build,
/// Set when the dev server runs the dev step to build only the modules.
modules_only: bool,
module_steps: []const *std.Build.Step,
configuration: std.Build.LazyPath,
native_registry: *std.Build.Module,
catalog: Catalog,

const HMR = @This();

pub fn init(b: *std.Build, executable: *std.Build.Step.Compile, options: Options) HMR {
    return initInner(b, executable, options) catch |err| std.debug.panic("failed to initialize HMR: {s}", .{@errorName(err)});
}

fn initInner(b: *std.Build, executable: *std.Build.Step.Compile, options: Options) !HMR {
    // The graph depends on the contents of the sources. A cached graph would
    // miss new modules.
    b.graph.poisonCache();
    const knots = options.knots.builder;
    const modules_only = b.option(bool, "knots_hmr_modules_only", "Internal: used by the HMR dev server") orelse false;
    const packages = try collectPackages(b, executable.root_module);
    const knots_decls = try portableDecls(b, knots);
    var cache: graph.Cache = .init(b.allocator);
    const resolved = try graph.resolve(b.allocator, b.graph.io, &cache, packages, knots_decls);
    const common = try commonDirectory(b, resolved.files);
    const host_target = executable.root_module.resolved_target.?;
    const host_optimize = executable.root_module.optimize.?;
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const guest_dependency = b.dependencyFromBuildZig(@import("build.zig"), .{
        .target = wasm_target,
        .optimize = .debug,
        .module_guest = true,
    });
    const guest: Guest = .{
        .knots = guest_dependency.module("knots"),
        .ui = guest_dependency.module("ui"),
        .hmr = guest_dependency.module("hmr"),
    };

    // Reloadable modules compile from private copies of the files they reach,
    // because each Zig copy gets a generated variable list (see snapshot.zig).
    // `original/` keeps the unchanged text.
    const snapshot_name = b.fmt("knots-modules/{x}", .{std.hash.Wyhash.hash(0, common)});
    const snapshot_directory = b.graph.path(.local_cache, snapshot_name);
    const Generated = struct { target: []const u8, contents: []const u8 };
    var copies: std.ArrayList(snapshot.Copy) = .empty;
    var generated: std.ArrayList(Generated) = .empty;
    for (resolved.module_files) |path| {
        const relative = try relativePath(b, common, path);
        const original: ?[]const u8 = if (std.mem.endsWith(u8, path, ".zig")) b.fmt("original/{s}", .{relative}) else null;
        try copies.append(b.allocator, .{
            .source = path,
            .target = b.fmt("tree/{s}", .{relative}),
            .original = original,
            .name = relative,
        });
    }
    const snapshot_run = b.addRunArtifact(snapshotTool(b, knots));
    snapshot_run.has_side_effects = true;

    // Reloadable builds install each module to `hmr/staging/<id>.wasm`.
    // Compiled-in builds run the host's own import of the module and only
    // embed its text, through `native_registry.zig`.
    var module_steps: std.ArrayList(*std.Build.Step) = .empty;
    const native_files = b.addWriteFiles();
    var registry: std.Io.Writer.Allocating = .init(b.allocator);
    try registry.writer.writeAll(
        \\pub const Entry = struct { id: []const u8, source: []const u8 };
        \\pub const entries = [_]Entry{
        \\
    );
    for (resolved.modules) |file| {
        const relative = try relativePath(b, common, file.path);
        const entry_name = try snapshot.entryName(b.allocator, file.id);
        const name = if (std.mem.lastIndexOfScalar(u8, file.id, '.')) |dot| file.id[dot + 1 ..] else file.id;
        var entry_copies: std.ArrayList([]const u8) = .empty;
        for (file.files) |path| {
            if (!std.mem.endsWith(u8, path, ".zig")) continue;
            try entry_copies.append(b.allocator, b.fmt("tree/{s}", .{try relativePath(b, common, path)}));
        }
        try generated.append(b.allocator, .{
            .target = entry_name,
            .contents = try snapshot.entryContents(b.allocator, entry_copies.items, b.fmt("original/{s}", .{relative})),
        });
        _ = native_files.addCopyFile(.{ .cwd_relative = file.path }, b.fmt("original/{s}", .{relative}));
        try registry.writer.print("    .{{ .id = {s}, .source = @embedFile({s}) }},\n", .{
            try quote(b, file.id),
            try quote(b, b.fmt("original/{s}", .{relative})),
        });
        const wasm = guestExecutable(b, knots, guest, wasm_target, name, snapshot_directory.path(b, entry_name));
        wasm.step.dependOn(&snapshot_run.step);
        const install = b.addInstallFileWithDir(wasm.getEmittedBin(), .prefix, b.fmt("hmr/staging/{s}.wasm", .{file.id}));
        try module_steps.append(b.allocator, &install.step);
    }
    try registry.writer.writeAll("};\n");

    const files = b.addWriteFiles();
    const snapshot_config = try std.json.Stringify.valueAlloc(b.allocator, .{
        .copies = copies.items,
        .generated = generated.items,
    }, .{});
    snapshot_run.addFileArg(files.add("snapshot.json", snapshot_config));
    snapshot_run.addDirectoryArg(snapshot_directory);
    executable.step.dependOn(&snapshot_run.step);

    const native_registry = b.createModule(.{
        .root_source_file = native_files.add("native_registry.zig", registry.written()),
        .target = host_target,
        .optimize = host_optimize,
    });

    // The server walks the same graph after each change. `copies` lets it
    // point build errors at the user's files.
    const configuration = files.add("server.json", try std.json.Stringify.valueAlloc(b.allocator, .{
        .packages = packages,
        .knots_decls = knots_decls,
        .copies = b.fmt("{s}/tree/", .{snapshot_name}),
        .sources = common,
    }, .{}));
    const module_ids = try b.allocator.alloc([]const u8, resolved.modules.len);
    for (resolved.modules, module_ids) |file, *id| id.* = file.id;
    const rejected_ids = try b.allocator.alloc([]const u8, resolved.rejections.len);
    const rejected_reasons = try b.allocator.alloc([]const u8, resolved.rejections.len);
    for (resolved.rejections, rejected_ids, rejected_reasons) |rejection, *id, *reason| {
        id.* = rejection.id;
        reason.* = rejection.reason;
    }
    const catalog: Catalog = .{
        .module_ids = module_ids,
        .rejected_ids = rejected_ids,
        .rejected_reasons = rejected_reasons,
    };
    const result: HMR = .{
        .builder = b,
        .executable = executable,
        .knots = knots,
        .modules_only = modules_only,
        .module_steps = module_steps.items,
        .configuration = configuration,
        .native_registry = native_registry,
        .catalog = catalog,
    };
    try result.injectRuntime(executable, runtimeModule(b, knots, host_target, host_optimize, true, catalog));
    return result;
}

/// Used by knots' own build: tests `Runtime.zig` against a fixture that goes
/// through the same copy and build steps as a module. `b` is the knots builder.
pub fn addRuntimeTest(b: *std.Build, target: std.Build.ResolvedTarget, guest: Guest) *std.Build.Step.Run {
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const fixture_source = b.root.joinString(b.allocator, "src/hmr/fixtures/counter.zig") catch @panic("OOM");
    const entry = snapshot.entryContents(b.allocator, &.{"counter.zig"}, "original.zig") catch @panic("OOM");
    const config = std.json.Stringify.valueAlloc(b.allocator, .{
        .copies = .{.{ .source = fixture_source, .target = "counter.zig", .original = "original.zig", .name = "counter.zig" }},
        .generated = .{.{ .target = "entry.zig", .contents = entry }},
    }, .{}) catch @panic("OOM");
    const snapshot_run = b.addRunArtifact(snapshotTool(b, b));
    snapshot_run.has_side_effects = true;
    snapshot_run.addFileArg(b.addWriteFiles().add("snapshot.json", config));
    const copy = snapshot_run.addOutputDirectoryArg("fixture");
    const fixture = guestExecutable(b, b, guest, wasm_target, "module-counter-fixture", copy.path(b, "entry.zig"));

    const test_module = runtimeModule(b, b, target, .debug, true, .{});
    test_module.addAnonymousImport("fixture_wasm", .{ .root_source_file = fixture.getEmittedBin() });
    const run = b.addRunArtifact(b.addTest(.{ .root_module = test_module }));
    if (b.lazyDependency("wasmtime", .{ .target = target, .optimize = .debug })) |wasmtime| {
        if (wasmtime.builder.named_lazy_paths.get("dll_dir")) |directory| run.setCwd(directory);
    }
    return run;
}

/// Attach compiled-in modules to a standalone native executable.
pub fn attachNative(self: *const HMR, executable: *std.Build.Step.Compile) void {
    const target = executable.root_module.resolved_target.?;
    const runtime = runtimeModule(self.builder, self.knots, target, executable.root_module.optimize.?, false, self.catalog);
    runtime.addImport("native_registry", self.native_registry);
    self.injectRuntime(executable, runtime) catch |err| std.debug.panic("failed to inject runtime: {s}", .{@errorName(err)});
}

fn snapshotTool(b: *std.Build, knots: *std.Build) *std.Build.Step.Compile {
    // Optimized, because it runs on every rebuild.
    return b.addExecutable(.{ .name = "knots-module-snapshot", .root_module = b.createModule(.{
        .root_source_file = knots.path("src/hmr/snapshot.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    }) });
}

fn module(knots: *std.Build, name: []const u8) *std.Build.Module {
    return knots.modules.get(name) orelse std.debug.panic("knots has no module named {s}", .{name});
}

fn runtimeModule(
    b: *std.Build,
    knots: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    reloadable: bool,
    catalog: Catalog,
) *std.Build.Module {
    const result = b.createModule(.{
        .root_source_file = knots.path("src/hmr/Runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hmr", .module = module(knots, "hmr") },
            .{ .name = "ui", .module = module(knots, "ui") },
            .{ .name = "input", .module = module(knots, "input") },
            .{ .name = "math", .module = module(knots, "math") },
            .{ .name = "render", .module = module(knots, "render") },
        },
    });
    const options = b.addOptions();
    options.addOption(bool, "reloadable", reloadable);
    options.addOption([]const []const u8, "module_ids", catalog.module_ids);
    options.addOption([]const []const u8, "rejected_ids", catalog.rejected_ids);
    options.addOption([]const []const u8, "rejected_reasons", catalog.rejected_reasons);
    result.addOptions("runtime_options", options);
    // Browser hosts run modules in JavaScript.
    if (reloadable and !target.result.cpu.arch.isWasm()) {
        if (knots.lazyDependency("wasmtime", .{ .target = target, .optimize = .debug })) |wasmtime| {
            result.addImport("wasmtime", wasmtime.module("wasmtime"));
        }
    }
    return result;
}

/// `source_root` is an entry (see `snapshot.entryContents`).
fn guestExecutable(b: *std.Build, knots: *std.Build, guest: Guest, target: std.Build.ResolvedTarget, name: []const u8, source_root: std.Build.LazyPath) *std.Build.Step.Compile {
    const source = b.createModule(.{
        .root_source_file = source_root,
        .target = target,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "knots", .module = guest.knots },
            .{ .name = "knots-ui", .module = guest.ui },
        },
    });
    const adapter = b.createModule(.{
        .root_source_file = knots.path("src/hmr/guest.zig"),
        .target = target,
        .optimize = .debug,
        .strip = true,
        .imports = &.{
            .{ .name = "hmr", .module = guest.hmr },
            .{ .name = "hmr_source", .module = source },
            .{ .name = "ui", .module = guest.ui },
        },
    });
    const wasm = b.addExecutable(.{ .name = name, .root_module = adapter });
    wasm.entry = .disabled;
    // Every save recompiles a module. The self-hosted backend does this about
    // 2x faster than LLVM.
    wasm.use_llvm = false;
    wasm.rdynamic = true;
    wasm.export_memory = true;
    wasm.initial_memory = 16 * 1024 * 1024;
    wasm.max_memory = 256 * 1024 * 1024;
    return wasm;
}

/// Replace each `knots` import in the executable and its own modules with a
/// facade that adds the module runtime.
fn injectRuntime(self: *const HMR, executable: *std.Build.Step.Compile, runtime: *std.Build.Module) !void {
    const facade = self.builder.createModule(.{
        .root_source_file = self.knots.path("src/modules.zig"),
        .target = executable.root_module.resolved_target.?,
        .optimize = executable.root_module.optimize.?,
        .imports = &.{
            .{ .name = "knots", .module = module(self.knots, "knots") },
            .{ .name = "modules", .module = runtime },
            .{ .name = "portable", .module = self.builder.createModule(.{
                .root_source_file = self.knots.path("src/portable.zig"),
                .target = executable.root_module.resolved_target.?,
                .optimize = executable.root_module.optimize.?,
                .imports = &.{.{ .name = "ui", .module = module(self.knots, "ui") }},
            }) },
        },
    });
    var pending: std.ArrayList(*std.Build.Module) = .empty;
    try pending.append(self.builder.allocator, executable.root_module);
    var next: usize = 0;
    while (next < pending.items.len) : (next += 1) {
        const current = pending.items[next];
        for (current.import_table.values()) |imported| {
            if (imported == runtime) continue;
            if (std.mem.indexOfScalar(*std.Build.Module, pending.items, imported) != null) continue;
            // Do not change modules of dependencies.
            if (imported.owner != self.builder) continue;
            try pending.append(self.builder.allocator, imported);
        }
        if (current.import_table.contains("knots")) current.addImport("knots", facade);
    }
}

/// Makes `step` run the host under the HMR server (src/hmr/server.zig). The
/// server runs `step` again with `-Dknots_hmr_modules_only` to rebuild the
/// modules, so no other top-level step is necessary.
pub fn addDevRunner(self: *const HMR, step: *std.Build.Step, options: DevOptions) void {
    const b = self.builder;
    if (self.modules_only) {
        for (self.module_steps) |module_step| step.dependOn(module_step);
        return;
    }
    const server = b.addExecutable(.{
        .name = "knots-hmr-server",
        .root_module = b.createModule(.{
            .root_source_file = self.knots.path("src/hmr/server.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    server.root_module.addImport("celer", self.knots.dependency("celer", .{
        .target = b.graph.host,
        .optimize = .fast,
    }).module("celer"));
    server.root_module.addImport("watch", self.knots.dependency("watch", .{
        .target = b.graph.host,
        .optimize = .fast,
    }).module("watch"));
    const browser_host = self.executable.root_module.resolved_target.?.result.cpu.arch.isWasm();
    if (browser_host) {
        const web_threads = self.knots.named_lazy_paths.contains("web-worker-js");
        web_build.configureExecutable(b, self.executable.root_module, self.executable, web_threads, .{});
    }

    const run = b.addRunArtifact(server);
    if (browser_host) {
        const install_wasm = b.addInstallFileWithDir(
            self.executable.getEmittedBin(),
            .{ .custom = options.web_dir },
            options.web_wasm_name,
        );
        install_wasm.step.dependOn(b.getInstallStep());
        run.step.dependOn(&install_wasm.step);
    }
    run.addPrefixedFileArg("--config=", self.configuration);
    run.addPrefixedFileArg("--zig=", .zig_exe);
    run.addPrefixedFileArg("--build-file=", options.build_file orelse b.path("build.zig"));
    run.addArg(b.fmt("--step={s}", .{step.name}));
    run.addPrefixedDirectoryArg("--prefix=", b.graph.path(.install_prefix, ""));
    run.addArg(b.fmt("--port={d}", .{options.port}));
    for (b.user_input_options.keys(), b.user_input_options.values()) |key, value| switch (value) {
        .flag => run.addArg(b.fmt("--build-arg=-D{s}", .{key})),
        .scalar => |scalar| run.addArg(b.fmt("--build-arg=-D{s}={s}", .{ key, scalar })),
        else => std.debug.panic("HMR dev runner: build option -D{s} is not a flag or scalar", .{key}),
    };
    for (options.build_arguments) |argument| run.addArg(b.fmt("--build-arg={s}", .{argument}));
    if (browser_host) {
        run.addPrefixedDirectoryArg("--web-dir=", b.graph.path(.install_prefix, options.web_dir));
        run.addArg(b.fmt("--host-module=/{s}", .{options.web_host_js_name}));
    } else {
        run.addPrefixedFileArg("--application=", self.executable.getEmittedBin());
    }
    run.addArg("--");
    run.addArgs(options.application_arguments);
    run.addPassthruArgs();
    step.dependOn(&run.step);
}

/// The executable's root module and the named modules of the application
/// that it imports, as packages for `graph.resolve`. Package 0 is the root.
fn collectPackages(b: *std.Build, root: *std.Build.Module) ![]const graph.Package {
    var modules: std.ArrayList(*std.Build.Module) = .empty;
    var packages: std.ArrayList(graph.Package) = .empty;
    try modules.append(b.allocator, root);
    try packages.append(b.allocator, .{ .root = (try sourcePath(b, root)).? });
    var next: usize = 0;
    while (next < modules.items.len) : (next += 1) {
        const current = modules.items[next];
        var imports: std.ArrayList(graph.Import) = .empty;
        for (current.import_table.keys(), current.import_table.values()) |name, imported| {
            const package = for (modules.items, 0..) |known, index| {
                if (known == imported) break index;
            } else package: {
                // Generated modules and modules of dependencies are not sources to walk.
                if (imported.owner != b) break :package null;
                const path = try sourcePath(b, imported) orelse break :package null;
                try modules.append(b.allocator, imported);
                try packages.append(b.allocator, .{ .root = path });
                break :package modules.items.len - 1;
            };
            try imports.append(b.allocator, .{ .name = name, .package = if (package) |index| @intCast(index) else null });
        }
        packages.items[next].imports = imports.items;
    }
    return packages.items;
}

/// The absolute path of the module's root source file, if it is a source.
fn sourcePath(b: *std.Build, module_: *std.Build.Module) !?[]const u8 {
    const file = module_.root_source_file orelse return null;
    const joined = switch (file) {
        .src_path => |source| try source.owner.root.joinString(b.allocator, source.sub_path),
        .cwd_relative => |source| source,
        else => return null,
    };
    return std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, joined, b.allocator) catch |err| {
        std.log.err("HMR source {s}: {t}", .{ joined, err });
        return err;
    };
}

/// The public declarations of the portable `knots` module, which modules may use.
fn portableDecls(b: *std.Build, knots: *std.Build) ![]const []const u8 {
    const path = try knots.root.joinString(b.allocator, "src/portable.zig");
    const source = try std.Io.Dir.cwd().readFileAllocOptions(b.graph.io, path, b.allocator, .limited(1024 * 1024), .of(u8), 0);
    return graph.publicDecls(b.allocator, source);
}

fn commonDirectory(b: *std.Build, files: []const []const u8) ![]const u8 {
    var common = std.fs.path.dirname(files[0]).?;
    for (files) |file| {
        while (std.mem.startsWith(u8, try relativePath(b, common, file), "..")) {
            common = std.fs.path.dirname(common) orelse {
                std.log.err("HMR sources {s} and {s} share no directory", .{ files[0], file });
                return error.SourcesOnDifferentFilesystems;
            };
        }
    }
    return common;
}

/// Uses forward slashes, because the result goes into generated imports.
fn relativePath(b: *std.Build, base: []const u8, path: []const u8) ![]u8 {
    const result = try std.fs.path.relativeAlloc(b.allocator, base, null, base, path);
    std.mem.replaceScalar(u8, result, '\\', '/');
    return result;
}

fn quote(b: *std.Build, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(b.allocator, text, .{});
}
