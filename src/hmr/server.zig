//! `zig build dev`: rebuilds HMR modules when their sources change and
//! publishes them to `<prefix>/hmr` (see protocol.zig). Native hosts read that
//! directory. Browser hosts get it, and change events, over HTTP.
//!
//! The server watches the files the application reaches from its entry point
//! (see graph.zig). If no imports changed, it rebuilds only the modules that
//! reach a changed file, without the build runner, which takes about 0.4 s of
//! a 1 s rebuild. The first change to a module replays the compiler command
//! that `zig build --verbose` printed for it, and starts an incremental
//! compiler (see `Compiler`) for the next changes. Other changes run
//! `zig build`. A change to a file that no module reaches needs a restart.

const std = @import("std");
const graph = @import("graph.zig");
const Events = @import("Events.zig");
const changes = @import("changes.zig");
const command = @import("command.zig");
const protocol = @import("protocol.zig");
const diagnostics = @import("diagnostics.zig");
const http_server = @import("http_server.zig");
const snapshot = @import("snapshot.zig");
const Watch = @import("watch");

const log = std.log.scoped(.hmr_server);

const rescan_interval_ms = 500;
const build_output_max = 256 * 1024;
const diagnostics_max = 24 * 1024;
const artifact_bytes_max = 64 * 1024 * 1024;

const compilers_max = 4;

const Configuration = struct {
    packages: []const graph.Package,
    knots_decls: []const []const u8,
    copies: []const u8,
    sources: []const u8,
};

const Host = struct {
    done: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
};

var interrupted: std.atomic.Value(bool) = .init(false);

const Arguments = struct {
    config_path: []const u8 = "",
    zig_exe: []const u8 = "",
    build_file: []const u8 = "",
    step: []const u8 = "",
    prefix: []const u8 = "",
    port: u16 = 0,
    web_directory: ?[]const u8 = null,
    host_module_path: []const u8 = "",
    application: ?[]const u8 = null,
    application_args: []const []const u8 = &.{},
    build_args: []const []const u8 = &.{},

    fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Arguments {
        var result: Arguments = .{};
        var build_args: std.ArrayList([]const u8) = .empty;
        for (args[1..], 1..) |arg, index| {
            if (std.mem.eql(u8, arg, "--")) {
                result.application_args = args[index + 1 ..];
                break;
            }

            const separator = std.mem.indexOfScalar(u8, arg, '=') orelse return error.ExpectedFlag;
            const name = arg[0..separator];
            const value = arg[separator + 1 ..];
            if (std.mem.eql(u8, name, "--config")) {
                result.config_path = value;
            } else if (std.mem.eql(u8, name, "--zig")) {
                result.zig_exe = value;
            } else if (std.mem.eql(u8, name, "--build-file")) {
                result.build_file = value;
            } else if (std.mem.eql(u8, name, "--step")) {
                result.step = value;
            } else if (std.mem.eql(u8, name, "--prefix")) {
                result.prefix = value;
            } else if (std.mem.eql(u8, name, "--port")) {
                result.port = try std.fmt.parseInt(u16, value, 10);
            } else if (std.mem.eql(u8, name, "--web-dir")) {
                result.web_directory = value;
            } else if (std.mem.eql(u8, name, "--host-module")) {
                result.host_module_path = value;
            } else if (std.mem.eql(u8, name, "--application")) {
                result.application = value;
            } else if (std.mem.eql(u8, name, "--build-arg")) {
                try build_args.append(allocator, value);
            } else return error.UnknownFlag;
        }
        result.build_args = build_args.items;
        const required = [_][]const u8{ result.config_path, result.zig_exe, result.build_file, result.step, result.prefix };
        for (required) |value| {
            if (value.len == 0)
                return error.MissingFlag;
        }

        if ((result.web_directory == null) == (result.application == null))
            return error.ExpectedWebDirectoryOrApplication;

        return result;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const arguments = try Arguments.parse(allocator, try init.minimal.args.toSlice(allocator));
    const config_bytes = try cwd.readFileAlloc(io, arguments.config_path, allocator, .limited(1024 * 1024));
    const config = try std.json.parseFromSliceLeaky(Configuration, allocator, config_bytes, .{ .ignore_unknown_fields = true });

    try cwd.createDirPath(io, arguments.prefix);
    const prefix = try cwd.realPathFileAlloc(io, arguments.prefix, allocator);
    const directory = try std.fs.path.join(allocator, &.{ prefix, "hmr" });
    try cwd.createDirPath(io, try std.fs.path.join(allocator, &.{ directory, "artifacts" }));

    // Two sessions on one prefix would use the same files and port.
    const lock_path = try std.fs.path.join(allocator, &.{ directory, "server.lock" });
    const lock = try cwd.createFile(io, lock_path, .{ .truncate = false });
    defer lock.close(io);
    if (!try lock.tryLock(io, .exclusive)) return error.HmrSessionAlreadyRunning;
    defer lock.unlock(io);

    var build_argv: std.ArrayList([]const u8) = .empty;

    // With this option, the dev step builds only the modules. `--verbose`
    // prints the compiler commands that later saves replay.
    try build_argv.appendSlice(allocator, &.{
        arguments.zig_exe,
        "build",
        arguments.step,
        "-Dknots_hmr_modules_only",
        "--build-file",
        arguments.build_file,
        "--prefix",
        prefix,
        "--verbose",
    });
    try build_argv.appendSlice(allocator, arguments.build_args);

    // The server parses the output of `zig build` and the compiler. A
    // terminal makes the outer `zig build` force colors on its children.
    var tool_environ = try init.environ_map.clone(allocator);
    try tool_environ.put("NO_COLOR", "1");
    var session: Session = .{
        .io = io,
        .gpa = init.gpa,
        .directory = directory,
        .config = config,
        .build_argv = build_argv.items,
        .environ = &tool_environ,
        .cache = .init(init.gpa),
    };
    defer session.cache.deinit();
    defer session.graph_arena.deinit();
    defer session.modules_arena.deinit();
    defer session.commands_arena.deinit();
    defer session.stopCompilers();

    var watch: Watch = .init(io, init.gpa);
    defer watch.deinit();

    var stamps_arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer stamps_arena.deinit();
    _ = try session.walk(&.{});
    // Watched before the first stamps, so no change falls between the two.
    watchGraph(&watch, allocator, &session.graph);
    var last_stamps = try changes.stamps(stamps_arena.allocator(), io, session.graph.files);
    // Without a first good build, there is nothing to serve.
    if (!try session.build()) return error.HmrBuildFailed;

    if (@import("builtin").os.tag != .windows) {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &action, null);
        std.posix.sigaction(.TERM, &action, null);
    }

    var host: Host = .{};
    var events: Events = .{};
    var publishes: ?std.Io.net.Server = null;
    defer if (publishes) |*listener| listener.deinit(io);
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(io);
    if (arguments.web_directory) |web_directory| {
        const http: http_server.Config = .{
            .web_directory = web_directory,
            .host_module_path = arguments.host_module_path,
            .hmr_directory = directory,
            .port = arguments.port,
        };
        try tasks.concurrent(io, serveHttp, .{ io, init.gpa, http, &events, &host });
        log.info("event=serving url=http://127.0.0.1:{d}", .{arguments.port});
    } else {
        var runner: std.ArrayList([]const u8) = .empty;
        try runner.append(allocator, arguments.application.?);
        try runner.appendSlice(allocator, arguments.application_args);
        const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        publishes = try loopback.listen(io, .{});
        try init.environ_map.put("KNOTS_HMR_DIR", directory);
        const events_address = try std.fmt.allocPrint(allocator, "{f}", .{publishes.?.socket.address});
        try init.environ_map.put("KNOTS_HMR_EVENTS", events_address);
        try tasks.concurrent(io, servePublishes, .{ io, &publishes.?, &events });
        try tasks.concurrent(io, runApplication, .{ io, runner.items, init.environ_map, &host });
    }

    while (!interrupted.load(.acquire) and !host.done.load(.acquire)) {
        _ = watch.wait(rescan_interval_ms);
        var next_arena: std.heap.ArenaAllocator = .init(init.gpa);
        const next_stamps = changes.stamps(next_arena.allocator(), io, session.graph.files) catch {
            next_arena.deinit();
            continue;
        };
        const changed = try changes.changed(next_arena.allocator(), last_stamps, next_stamps);
        if (changed.len == 0) {
            next_arena.deinit();
            continue;
        }

        const reshaped = session.walk(changed) catch |err| {
            log.warn("event=graph_failed error={t} action=retry", .{err});
            next_arena.deinit();
            continue;
        };

        var current = next_stamps;
        if (reshaped) {
            watchGraph(&watch, allocator, &session.graph);
            current = try changes.stamps(next_arena.allocator(), io, session.graph.files);
        }
        stamps_arena.deinit();
        stamps_arena = next_arena;
        last_stamps = current;
        const published = session.rebuild(changed, reshaped) catch |err| published: {
            log.err("event=build_failed error={t}", .{err});
            break :published false;
        };

        if (published)
            events.publish(io);
    }

    if (host.failed.load(.acquire))
        return error.HostFailed;
}

/// Watches the directories of the graph's files. On failure, the rescan
/// interval still finds changes.
fn watchGraph(watch: *Watch, allocator: std.mem.Allocator, result: *const graph.Result) void {
    var directories: std.ArrayList([]const u8) = .empty;
    for (result.files) |file| {
        const directory = std.fs.path.dirname(file) orelse continue;
        for (directories.items) |known| {
            if (std.mem.eql(u8, known, directory)) break;
        } else directories.append(allocator, directory) catch return;
    }
    watch.setDirectories(directories.items) catch |err| {
        log.warn("event=file_events_failed error={t} action=rescan interval_ms={d}", .{ err, rescan_interval_ms });
    };
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

const Session = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    directory: []const u8,
    config: Configuration,
    build_argv: []const []const u8,
    environ: *const std.process.Environ.Map,
    modules: []const protocol.Entry = &.{},
    graph: graph.Result = .{},
    graph_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    cache: graph.Cache,
    modules_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    commands: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    snapshot: ?struct { directory: []const u8, copies: []const snapshot.Copy } = null,
    commands_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    compilers: std.StringArrayHashMapUnmanaged(*Compiler) = .empty,
    clock: u64 = 0,

    /// Parses the changed files again and walks the application. Returns
    /// true if its files or modules changed.
    fn walk(self: *Session, changed: []const []const u8) !bool {
        for (changed) |path| self.cache.invalidate(path);
        var next_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        errdefer next_arena.deinit();
        const resolved = try graph.resolve(next_arena.allocator(), self.io, &self.cache, self.config.packages, self.config.knots_decls);
        const reshaped = !resolved.sameShape(&self.graph);
        self.graph_arena.deinit();
        self.graph_arena = next_arena;
        self.graph = resolved;
        return reshaped;
    }

    /// Rebuilds only the modules that reach a changed file, if no imports
    /// changed. Otherwise runs `zig build`. `reshaped` is the result of
    /// `walk`. Returns true if it published a manifest.
    fn rebuild(self: *Session, changed: []const []const u8, reshaped: bool) !bool {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const allocator = arena.allocator();
        const started_at = std.Io.Clock.awake.now(self.io);
        if (reshaped) return self.fullBuild("graph_changed", "");
        const recorded = self.snapshot orelse return self.fullBuild("no_snapshot", "");
        var ids: std.ArrayList([]const u8) = .empty;
        var copies: std.ArrayList(snapshot.Copy) = .empty;
        for (changed) |path| {
            var reached = false;
            for (self.graph.modules) |module| {
                if (!module.reaches(path)) continue;
                reached = true;
                if (!self.commands.contains(module.id)) return self.fullBuild("no_command", path);
                for (ids.items) |id| {
                    if (std.mem.eql(u8, id, module.id)) break;
                } else try ids.append(allocator, module.id);
            }
            if (!reached) continue;
            const copy = for (recorded.copies) |copy| {
                if (std.mem.eql(u8, copy.source, path)) break copy;
            } else return self.fullBuild("no_copy", path);
            try copies.append(allocator, copy);
        }
        if (ids.items.len == 0) {
            log.info("event=host_file_changed action=restart_to_apply", .{});
            return false;
        }

        // Only the copies of the changed files change. This skips the
        // snapshot tool, which compares every copy.
        for (copies.items) |copy| {
            snapshot.writeCopy(allocator, self.io, recorded.directory, copy) catch |err| {
                log.warn("event=copy_failed path={s} error={t}", .{ copy.source, err });
                return self.fullBuild("copy_failed", copy.source);
            };
        }
        var compile_path: []const u8 = "incremental";
        for (ids.items) |id| {
            const compiled = try self.compile(allocator, id);
            if (!compiled.incremental) compile_path = "direct";
            const errors = compiled.errors orelse continue;

            // Any other failure can mean that the command is stale.
            if (!diagnostics.hasLocated(errors))
                return self.fullBuild("unlocated_errors", id);

            try self.fail(allocator, errors, started_at);
            return true;
        }

        // A module without an artifact would disappear from the manifest.
        if (!try self.publishStaged(allocator, ids.items))
            return self.fullBuild("missing_artifact", "");

        log.info("event=published modules={d} rebuilt={d} path={s} duration_ms={d}", .{
            self.modules.len,
            ids.items.len,
            compile_path,
            elapsedMilliseconds(self.io, started_at),
        });

        return true;
    }

    fn fullBuild(self: *Session, reason: []const u8, path: []const u8) !bool {
        log.info("event=full_build reason={s} path={s}", .{ reason, path });
        _ = try self.build();
        return true;
    }

    const Compiled = struct { errors: ?[]const u8 = null, incremental: bool };

    /// Builds one module to `staging/<id>.wasm` with its incremental compiler.
    /// Without one, replays the stored command and starts a compiler for the
    /// next change.
    fn compile(self: *Session, allocator: std.mem.Allocator, id: []const u8) !Compiled {
        const staged = try self.stagedPath(allocator, id);
        if (self.compilers.get(id)) |compiler| {
            self.clock += 1;
            compiler.used = self.clock;
            if (compiler.update(allocator)) |result| switch (result) {
                .binary => |binary| {
                    const bytes = try readArtifact(allocator, self.io, binary);
                    try atomicWrite(allocator, self.io, staged, bytes);
                    return .{ .incremental = true };
                },
                .errors => |errors| {
                    if (diagnostics.hasLocated(errors)) return .{ .errors = errors, .incremental = true };
                    // The replayed command shows if the error is real.
                    log.warn("event=compiler_failed module_id={s} error=unlocated_diagnostics action=replay_command", .{id});
                    self.stopCompiler(id);
                },
            } else |err| {
                log.warn("event=compiler_failed module_id={s} error={t} action=replay_command", .{ id, err });
                self.stopCompiler(id);
            }
        }

        const stored = self.commands.get(id).?;
        var argv: std.ArrayList([]const u8) = .empty;
        for (stored) |arg| {
            if (!std.mem.eql(u8, arg, "--listen=-"))
                try argv.append(allocator, arg);
        }
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{staged}));
        const result = try self.run(allocator, argv.items);

        self.startCompiler(id, stored) catch |err|
            log.warn("event=compiler_start_failed module_id={s} error={t}", .{ id, err });

        return .{ .errors = if (result.term.success()) null else result.stderr, .incremental = false };
    }

    /// Stops the least recently used compiler if `compilers_max` run.
    fn startCompiler(self: *Session, id: []const u8, stored: []const []const u8) !void {
        if (self.compilers.count() == compilers_max) {
            const compilers = self.compilers.values();
            var oldest: usize = 0;
            for (compilers, 0..) |compiler, index| {
                if (compiler.used < compilers[oldest].used) oldest = index;
            }
            self.stopCompiler(compilers[oldest].id);
        }
        const compiler = try Compiler.start(self.gpa, self.io, self.environ, id, stored);
        errdefer compiler.stop();
        self.clock += 1;
        compiler.used = self.clock;
        try self.compilers.put(self.gpa, compiler.id, compiler);
        log.info("event=compiler_started module_id={s} compilers={d}", .{ id, self.compilers.count() });
    }

    fn stopCompiler(self: *Session, id: []const u8) void {
        const entry = self.compilers.fetchSwapRemove(id) orelse return;
        entry.value.stop();
    }

    /// After `zig build`, stops each compiler whose command changed.
    fn stopStaleCompilers(self: *Session) void {
        var index = self.compilers.count();
        while (index > 0) {
            index -= 1;
            const compiler = self.compilers.values()[index];
            const stored = self.commands.get(compiler.id) orelse &.{};
            if (sameCommand(stored, compiler.command)) continue;
            self.compilers.swapRemoveAt(index);
            compiler.stop();
        }
    }

    fn stopCompilers(self: *Session) void {
        for (self.compilers.values()) |compiler| compiler.stop();
        self.compilers.deinit(self.gpa);
    }

    /// Runs `zig build`, publishes the result and stores the commands for
    /// replay. Returns false if the build failed.
    fn build(self: *Session) !bool {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const allocator = arena.allocator();
        const started_at = std.Io.Clock.awake.now(self.io);

        // Only modules installed by this build may enter the manifest.
        try std.Io.Dir.cwd().deleteTree(self.io, try std.fs.path.join(allocator, &.{ self.directory, "staging" }));
        const result = try self.run(allocator, self.build_argv);
        try self.recordCommands(result.stderr);
        self.stopStaleCompilers();
        if (!result.term.success()) {
            const output = if (result.stderr.len > 0) result.stderr else result.stdout;
            try self.fail(allocator, output, started_at);
            return false;
        }
        _ = try self.publishStaged(allocator, null);
        log.info("event=published modules={d} duration_ms={d}", .{ self.modules.len, elapsedMilliseconds(self.io, started_at) });
        return true;
    }

    /// Publishes the staged modules. With `rebuilt`, only those modules are
    /// read, and the others keep their published artifacts. Then a module
    /// without one returns false and publishes nothing. Without `rebuilt`,
    /// every staged module is read, and a module without one is left out.
    fn publishStaged(self: *Session, allocator: std.mem.Allocator, rebuilt: ?[]const []const u8) !bool {
        var next_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        errdefer next_arena.deinit();
        var modules: std.ArrayList(protocol.Entry) = .empty;
        for (self.graph.modules) |file| {
            const hash = try self.moduleHash(allocator, file.id, rebuilt) orelse {
                if (rebuilt != null) {
                    next_arena.deinit();
                    return false;
                }
                // Added after the build started. The next build includes it.
                continue;
            };
            try modules.append(next_arena.allocator(), .{
                .id = try next_arena.allocator().dupe(u8, file.id),
                .hash = try next_arena.allocator().dupe(u8, hash),
            });
        }
        try self.publish(allocator, modules.items, null);
        self.modules_arena.deinit();
        self.modules_arena = next_arena;
        self.modules = modules.items;
        try self.prune(allocator);
        return true;
    }

    /// The artifact hash of a module, or null if it has none. A module that
    /// is not in `rebuilt` keeps its published artifact.
    fn moduleHash(self: *Session, allocator: std.mem.Allocator, id: []const u8, rebuilt: ?[]const []const u8) !?[]const u8 {
        if (rebuilt) |ids| {
            if (!contains(ids, id)) {
                for (self.modules) |entry| {
                    if (std.mem.eql(u8, entry.id, id))
                        return entry.hash;
                }

                return null;
            }
        }

        const staged = try self.stagedPath(allocator, id);
        const bytes = readArtifact(allocator, self.io, staged) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };

        const hash = protocol.contentHash(bytes);
        const artifact = try std.fmt.allocPrint(allocator, "{s}/artifacts/{s}.wasm", .{ self.directory, &hash });
        // Artifacts are named by content, so an existing one is current.
        std.Io.Dir.cwd().access(self.io, artifact, .{}) catch try atomicWrite(allocator, self.io, artifact, bytes);
        return try allocator.dupe(u8, &hash);
    }

    /// Publishes the diagnostics with the last working modules.
    fn fail(self: *Session, allocator: std.mem.Allocator, output: []const u8, started_at: std.Io.Timestamp) !void {
        const summary = try self.buildErrors(allocator, output);
        std.debug.print("{s}\n", .{summary});
        try self.publish(allocator, self.modules, summary);
        log.warn("event=build_failed duration_ms={d} action=keep_last_working_modules", .{elapsedMilliseconds(self.io, started_at)});
    }

    fn recordCommands(self: *Session, output: []const u8) !void {
        var commands: std.StringHashMapUnmanaged([]const []const u8) = .empty;
        var recorded: @FieldType(Session, "snapshot") = null;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        errdefer arena.deinit();

        const allocator = arena.allocator();
        const files = self.graph.modules;
        const entries = try allocator.alloc([]const u8, files.len);
        for (files, entries) |file, *entry| {
            entry.* = try snapshot.entryName(allocator, file.id);
        }

        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            const argv = try verboseCommand(allocator, line) orelse continue;
            // `knots-module-snapshot <snapshot.json> <directory>`
            if (std.mem.eql(u8, std.fs.path.basename(argv[0]), "knots-module-snapshot")) {
                if (argv.len != 3)
                    continue;

                const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, argv[1], allocator, .limited(32 * 1024 * 1024));
                const configuration = try std.json.parseFromSliceLeaky(snapshot.Configuration, allocator, bytes, .{});
                recorded = .{ .directory = argv[2], .copies = configuration.copies };
                continue;
            }

            const source = flagSuffix(argv, "-Mhmr_source=") orelse continue;
            for (files, entries) |file, entry| {
                if (!std.mem.eql(u8, std.fs.path.basename(source), entry))
                    continue;

                try commands.put(allocator, try allocator.dupe(u8, file.id), argv);
            }
        }
        if (recorded == null) {
            arena.deinit();
            return;
        }
        self.commands_arena.deinit();
        self.commands_arena = arena;
        self.commands = commands;
        self.snapshot = recorded;
    }

    /// The command that `zig build --verbose` printed on `line`, if any.
    fn verboseCommand(allocator: std.mem.Allocator, line: []const u8) !?[]const []const u8 {
        const prefix = "info(verbose): ";
        if (!std.mem.startsWith(u8, line, prefix))
            return null;
        return command.parse(allocator, line[prefix.len..]);
    }

    /// The rest of the first argument that starts with `prefix`.
    fn flagSuffix(argv: []const []const u8, prefix: []const u8) ?[]const u8 {
        for (argv) |arg| {
            if (std.mem.startsWith(u8, arg, prefix))
                return arg[prefix.len..];
        }
        return null;
    }

    fn buildErrors(self: *Session, allocator: std.mem.Allocator, output: []const u8) ![]const u8 {
        const copies_windows = try allocator.dupe(u8, self.config.copies);
        std.mem.replaceScalar(u8, copies_windows, '/', '\\');
        var text = try diagnostics.sourcePaths(allocator, output, self.config.copies, self.config.sources);
        text = try diagnostics.sourcePaths(allocator, text, copies_windows, self.config.sources);
        const summary = try diagnostics.summary(allocator, text);

        if (summary.len == 0)
            return "The build failed without diagnostics.";

        return summary[0..@min(summary.len, diagnostics_max)];
    }

    fn publish(self: *Session, allocator: std.mem.Allocator, modules: []const protocol.Entry, build_error: ?[]const u8) !void {
        const manifest: protocol.Manifest = .{ .modules = modules, .build_error = build_error };
        const bytes = try std.json.Stringify.valueAlloc(allocator, manifest, .{});
        try atomicWrite(allocator, self.io, try std.fs.path.join(allocator, &.{ self.directory, "manifest.json" }), bytes);
    }

    fn stagedPath(self: *const Session, allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/staging/{s}.wasm", .{ self.directory, id });
    }

    fn run(self: *const Session, allocator: std.mem.Allocator, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(allocator, self.io, .{
            .argv = argv,
            .environ_map = self.environ,
            .stdout_limit = .limited(build_output_max),
            .stderr_limit = .limited(build_output_max),
        });
    }

    /// Every edit adds an artifact, so remove the ones the manifest does not name.
    fn prune(self: *Session, allocator: std.mem.Allocator) !void {
        const path = try std.fs.path.join(allocator, &.{ self.directory, "artifacts" });
        var artifacts = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer artifacts.close(self.io);
        var stale: std.ArrayList([]const u8) = .empty;
        var iterator = artifacts.iterate();
        while (try iterator.next(self.io)) |entry| {
            const current = for (self.modules) |module| {
                if (std.mem.eql(u8, std.fs.path.stem(entry.name), module.hash))
                    break true;
            } else false;

            if (!current)
                try stale.append(allocator, try allocator.dupe(u8, entry.name));
        }
        for (stale.items) |name| artifacts.deleteFile(self.io, name) catch {};
    }
};

/// A `zig build-exe -fincremental --listen=-` process for one module.
const Compiler = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    command: []const []const u8,
    cache: []const u8,
    name: []const u8,
    child: std.process.Child,
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,
    read_buffer: [64 * 1024]u8,
    write_buffer: [64]u8,
    pending: bool = false,
    used: u64 = 0,

    const Result = union(enum) { binary: []const u8, errors: []const u8 };

    fn start(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, id: []const u8, stored: []const []const u8) !*Compiler {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();

        const allocator = arena.allocator();
        const owned = try allocator.alloc([]const u8, stored.len);

        for (stored, owned) |arg, *copy|
            copy.* = try allocator.dupe(u8, arg);

        var argv: std.ArrayList([]const u8) = .empty;
        for (owned) |arg| {
            if (isCompilerServerFlag(arg))
                continue;
            try argv.append(allocator, arg);
        }

        try argv.appendSlice(allocator, &.{ "--listen=-", "-fincremental" });
        const owned_id = try allocator.dupe(u8, id);
        const cache = flagValue(owned, "--cache-dir") orelse return error.CommandHasNoCacheDirectory;
        const name = flagValue(owned, "--name") orelse return error.CommandHasNoName;

        const self = try gpa.create(Compiler);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena = arena,
            .id = owned_id,
            .command = owned,
            .cache = cache,
            .name = name,
            .child = try std.process.spawn(io, .{
                .argv = argv.items,
                .environ_map = environ,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .ignore,
            }),
            .reader = undefined,
            .writer = undefined,
            .read_buffer = undefined,
            .write_buffer = undefined,
        };
        errdefer self.child.kill(io);
        self.reader = self.child.stdout.?.readerStreaming(io, &self.read_buffer);
        self.writer = self.child.stdin.?.writerStreaming(io, &self.write_buffer);
        try self.requestUpdate();
        return self;
    }

    /// Flags that `start` replaces to run the compiler as a server.
    fn isCompilerServerFlag(arg: []const u8) bool {
        return std.mem.eql(u8, arg, "--listen=-") or
            std.mem.eql(u8, arg, "-fincremental") or
            std.mem.eql(u8, arg, "-fno-incremental");
    }

    /// The argument after the last `flag`.
    fn flagValue(argv: []const []const u8, flag: []const u8) ?[]const u8 {
        var result: ?[]const u8 = null;
        for (1..argv.len) |index| {
            if (std.mem.eql(u8, argv[index - 1], flag))
                result = argv[index];
        }
        return result;
    }

    fn stop(self: *Compiler) void {
        self.child.kill(self.io);
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn update(self: *Compiler, allocator: std.mem.Allocator) !Result {
        if (self.pending)
            _ = try self.receive(allocator);

        try self.requestUpdate();
        return self.receive(allocator);
    }

    fn requestUpdate(self: *Compiler) !void {
        const header: std.zig.Client.Message.Header = .{ .tag = .update, .bytes_len = 0 };
        try self.writer.interface.writeStruct(header, .little);
        try self.writer.interface.flush();
        self.pending = true;
    }

    fn receive(self: *Compiler, allocator: std.mem.Allocator) !Result {
        const in = &self.reader.interface;
        var digest: ?std.Build.Cache.BinDigest = null;
        while (true) {
            const header = try in.takeStruct(std.zig.Server.Message.Header, .little);
            switch (header.tag) {
                .emit_digest => {
                    const body = try in.take(header.bytes_len);
                    const size = @sizeOf(std.zig.Server.Message.EmitDigest);
                    if (body.len < size + std.Build.Cache.bin_digest_len) return error.InvalidMessage;
                    digest = body[size..][0..std.Build.Cache.bin_digest_len].*;
                },
                .error_bundle => {
                    self.pending = false;
                    const body = try in.readAllocAll(allocator, header.bytes_len);
                    const bundle = try std.zig.Server.allocErrorBundle(allocator, body);
                    if (bundle.errorMessageCount() > 0) {
                        var text: std.Io.Writer.Allocating = .init(allocator);
                        try bundle.renderToWriter(.{}, &text.writer);
                        return .{ .errors = text.written() };
                    }
                    const hex = std.fmt.bytesToHex(digest orelse return error.MissingBinary, .lower);
                    const binary = try std.fmt.allocPrint(allocator, "{s}/o/{s}/{s}.wasm", .{ self.cache, &hex, self.name });
                    return .{ .binary = binary };
                },
                else => try in.discardAll(header.bytes_len),
            }
        }
    }
};

fn serveHttp(io: std.Io, gpa: std.mem.Allocator, config: http_server.Config, events: *Events, host: *Host) void {
    defer host.done.store(true, .release);
    http_server.serve(io, gpa, config, events) catch |err| {
        if (err == error.Canceled)
            return;

        log.err("event=http_server_failed error={t}", .{err});
    };
    host.failed.store(true, .release);
}

fn servePublishes(io: std.Io, listener: *std.Io.net.Server, events: *Events) void {
    var hosts: std.Io.Group = .init;
    defer hosts.cancel(io);
    while (true) {
        const stream = listener.accept(io) catch |err| {
            if (err != error.Canceled)
                log.err("event=events_accept_failed error={t}", .{err});

            return;
        };
        hosts.concurrent(io, notifyHost, .{ io, stream, events }) catch stream.close(io);
    }
}

/// Sends one byte after each publish, so the host does not poll the manifest.
fn notifyHost(io: std.Io, stream: std.Io.net.Stream, events: *Events) std.Io.Cancelable!void {
    defer stream.close(io);
    var writer = stream.writer(io, &.{});
    events.mutex.lockUncancelable(io);
    var revision = events.revision;
    while (true) {
        while (events.revision == revision) events.condition.wait(io, &events.mutex) catch |err| {
            events.mutex.unlock(io);
            return err;
        };
        revision = events.revision;
        events.mutex.unlock(io);
        // The host exited.
        writer.interface.writeByte(0) catch return;
        events.mutex.lockUncancelable(io);
    }
}

fn runApplication(io: std.Io, argv: []const []const u8, environment: *const std.process.Environ.Map, host: *Host) void {
    defer host.done.store(true, .release);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = environment,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        log.err("event=application_start_failed error={t}", .{err});
        host.failed.store(true, .release);
        return;
    };
    // `wait` clears the id when canceled. Restore it so `kill` still works.
    const id = child.id;
    defer child.kill(io);
    const term = child.wait(io) catch |err| {
        child.id = id;
        if (err != error.Canceled) log.err("event=application_wait_failed error={t}", .{err});
        return;
    };
    if (!term.success()) {
        log.err("event=application_exited term={any}", .{term});
        host.failed.store(true, .release);
    }
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, item))
            return true;
    }
    return false;
}

fn sameCommand(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_arg, right_arg| {
        if (!std.mem.eql(u8, left_arg, right_arg))
            return false;
    }
    return true;
}

fn readArtifact(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(artifact_bytes_max));
}

fn atomicWrite(allocator: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = bytes, .flags = .{} });
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
}

fn elapsedMilliseconds(io: std.Io, started_at: std.Io.Timestamp) i64 {
    return started_at.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
}
