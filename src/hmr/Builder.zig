//! Runs `zig build --verbose` once for the app's compiler command, then
//! reruns that command as an incremental compiler on each change.

const std = @import("std");
const changes = @import("changes.zig");
const command_line = @import("command.zig");
const diagnostics = @import("diagnostics.zig");
const Watch = @import("watch");

const Builder = @This();
const log = std.log.scoped(.hmr);

const rescan_interval_ms = 500;
const build_output_max = 256 * 1024;
const diagnostics_max = 24 * 1024;
const artifact_bytes_max = 64 * 1024 * 1024;

pub const Options = struct {
    zig_exe: []const u8 = "",
    build_file: []const u8 = "",
    step: []const u8 = "",
    artifact_name: []const u8 = "",
    prefix: []const u8 = "",
    build_args: []const []const u8 = &.{},

    pub fn parse(self: *Options, allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
        var build_args: std.ArrayList([]const u8) = .empty;
        var rest: std.ArrayList([]const u8) = .empty;
        for (args) |arg| {
            const separator = std.mem.indexOfScalar(u8, arg, '=') orelse return error.ExpectedFlag;
            const name = arg[0..separator];
            const value = arg[separator + 1 ..];
            if (std.mem.eql(u8, name, "--zig")) {
                self.zig_exe = value;
            } else if (std.mem.eql(u8, name, "--build-file")) {
                self.build_file = value;
            } else if (std.mem.eql(u8, name, "--artifact-name")) {
                self.artifact_name = value;
            } else if (std.mem.eql(u8, name, "--step")) {
                self.step = value;
            } else if (std.mem.eql(u8, name, "--prefix")) {
                self.prefix = value;
            } else if (std.mem.eql(u8, name, "--build-arg")) {
                try build_args.append(allocator, value);
            } else try rest.append(allocator, arg);
        }
        self.build_args = build_args.items;
        for ([_][]const u8{ self.artifact_name, self.zig_exe, self.build_file, self.step, self.prefix }) |value| {
            if (value.len == 0) return error.MissingFlag;
        }
        return rest.items;
    }
};

pub const Result = union(enum) { app: []const u8, failed: []const u8 };

pub const Publisher = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, Result) void,
};

io: std.Io,
gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
directory: []const u8,
lock: std.Io.File,
build_argv: []const []const u8,
build_file: []const u8,
artifact_name: []const u8,
environ: std.process.Environ.Map,
publisher: Publisher,
command: []const []const u8 = &.{},
command_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
compiler: ?*Compiler = null,
inputs: []const []const u8 = &.{},
inputs_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
inputs_revision: u64 = 0,

pub fn init(io: std.Io, gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, options: Options, publisher: Publisher) !*Builder {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, options.prefix);
    const prefix = try cwd.realPathFileAlloc(io, options.prefix, allocator);
    const directory = try std.fs.path.join(allocator, &.{ prefix, "hmr" });
    try cwd.createDirPath(io, directory);

    // Two sessions on one prefix would use the same files.
    const lock = try cwd.createFile(io, try std.fs.path.join(allocator, &.{ directory, "server.lock" }), .{ .truncate = false });
    errdefer lock.close(io);
    if (!try lock.tryLock(io, .exclusive)) return error.HmrSessionAlreadyRunning;
    errdefer lock.unlock(io);

    var build_argv: std.ArrayList([]const u8) = .empty;
    try build_argv.appendSlice(allocator, &.{ options.zig_exe, "build", options.step, "-Dknots_hmr_app_only", "--build-file", options.build_file, "--prefix", prefix, "--verbose" });
    try build_argv.appendSlice(allocator, options.build_args);

    // A terminal would make `zig build` force colors on its children.
    var tool_environ = try environ.clone(allocator);
    try tool_environ.put("NO_COLOR", "1");

    const self = try gpa.create(Builder);
    errdefer gpa.destroy(self);
    self.* = .{
        .io = io,
        .gpa = gpa,
        .arena = arena,
        .directory = directory,
        .lock = lock,
        .build_argv = build_argv.items,
        .build_file = try cwd.realPathFileAlloc(io, options.build_file, allocator),
        .artifact_name = options.artifact_name,
        .environ = tool_environ,
        .publisher = publisher,
    };
    return self;
}

pub fn start(self: *Builder) !void {
    if (!try self.build()) return error.HmrBuildFailed;
}

pub fn watch(self: *Builder, stop: *const std.atomic.Value(bool)) void {
    self.watchChanges(stop) catch |err| log.err("event=watch_failed error={t}", .{err});
}

fn watchChanges(self: *Builder, stop: *const std.atomic.Value(bool)) !void {
    var watcher: Watch = .init(self.io, self.gpa);
    defer watcher.deinit();

    // Watched before the first stamps, so no change falls between the two.
    watchInputs(&watcher, self.gpa, self.inputs);
    var stamps_arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer stamps_arena.deinit();
    var last_stamps = try changes.stamps(stamps_arena.allocator(), self.io, self.inputs);
    var watched_revision = self.inputs_revision;

    while (!stop.load(.acquire)) {
        _ = watcher.wait(rescan_interval_ms);
        var next_arena: std.heap.ArenaAllocator = .init(self.gpa);
        const next_stamps = changes.stamps(next_arena.allocator(), self.io, self.inputs) catch {
            next_arena.deinit();
            continue;
        };
        const changed = try changes.changed(next_arena.allocator(), last_stamps, next_stamps);
        if (changed.len == 0) {
            next_arena.deinit();
            continue;
        }

        stamps_arena.deinit();
        stamps_arena = next_arena;
        last_stamps = next_stamps;
        self.rebuild(changed) catch |err| log.err("event=build_failed error={t}", .{err});

        if (watched_revision != self.inputs_revision) {
            watched_revision = self.inputs_revision;
            watchInputs(&watcher, self.gpa, self.inputs);
            last_stamps = try changes.stamps(stamps_arena.allocator(), self.io, self.inputs);
        }
    }
}

pub fn deinit(self: *Builder) void {
    self.stopCompiler();
    self.command_arena.deinit();
    self.inputs_arena.deinit();
    self.lock.unlock(self.io);
    self.lock.close(self.io);
    const gpa = self.gpa;
    self.arena.deinit();
    gpa.destroy(self);
}

fn rebuild(self: *Builder, changed: []const []const u8) !void {
    for (changed) |path| {
        if (std.mem.eql(u8, path, self.build_file))
            return self.fullBuild("build_script_changed");
    }

    const compiler = self.compiler orelse return self.fullBuild("no_compiler");
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const started_at = std.Io.Clock.awake.now(self.io);
    const result = compiler.update(allocator) catch |err| {
        log.warn("event=compiler_failed error={t} action=full_build", .{err});
        self.stopCompiler();
        return self.fullBuild("compiler_failed");
    };
    try self.setInputs(compiler.inputs);
    switch (result) {
        .binary => |path| self.publisher.publish(self.publisher.context, .{ .app = try readArtifact(allocator, self.io, path) }),
        .errors => |errors| {
            // Any other failure can mean that the command is stale.
            if (!diagnostics.hasLocated(errors)) {
                self.stopCompiler();
                return self.fullBuild("unlocated_errors");
            }
            return self.fail(allocator, errors, started_at);
        },
    }
    log.info("event=published path=incremental duration_ms={d}", .{elapsedMilliseconds(self.io, started_at)});
}

fn fullBuild(self: *Builder, reason: []const u8) !void {
    log.info("event=full_build reason={s}", .{reason});
    _ = try self.build();
}

fn build(self: *Builder) !bool {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const started_at = std.Io.Clock.awake.now(self.io);

    // Only a build installed by this run may be published.
    const staged = try std.fs.path.join(allocator, &.{ self.directory, "staging", "app.wasm" });
    std.Io.Dir.cwd().deleteFile(self.io, staged) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const result = try self.run(allocator, self.build_argv);
    const changed = try self.recordCommand(result.stderr);
    if (!result.term.success()) {
        const output = if (result.stderr.len > 0) result.stderr else result.stdout;
        try self.fail(allocator, output, started_at);
        return false;
    }
    self.publisher.publish(self.publisher.context, .{ .app = try readArtifact(allocator, self.io, staged) });
    log.info("event=published path=full duration_ms={d}", .{elapsedMilliseconds(self.io, started_at)});

    if (changed or self.compiler == null) {
        self.stopCompiler();
        self.startCompiler() catch |err|
            log.warn("event=compiler_start_failed error={t} action=full_builds", .{err});
    }
    return true;
}

fn startCompiler(self: *Builder) !void {
    if (self.command.len == 0) return error.NoAppCommand;
    const compiler = try Compiler.start(self.gpa, self.io, &self.environ, self.command);
    errdefer compiler.stop();

    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    _ = try compiler.receive(arena.allocator());
    try self.setInputs(compiler.inputs);
    self.compiler = compiler;
    log.info("event=compiler_started inputs={d}", .{self.inputs.len});
}

fn stopCompiler(self: *Builder) void {
    const compiler = self.compiler orelse return;
    compiler.stop();
    self.compiler = null;
}

/// The build script is always an input, so a change to it is seen.
fn setInputs(self: *Builder, files: []const []const u8) !void {
    if (self.inputs.len == files.len + 1) same: {
        for (files) |file| {
            if (!contains(self.inputs, file)) break :same;
        }
        return;
    }
    var next: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    errdefer next.deinit();
    const inputs = try next.allocator().alloc([]const u8, files.len + 1);
    for (files, inputs[0..files.len]) |file, *input| input.* = try next.allocator().dupe(u8, file);
    inputs[files.len] = try next.allocator().dupe(u8, self.build_file);
    std.mem.sort([]const u8, inputs, {}, lessThan);
    self.inputs_arena.deinit();
    self.inputs_arena = next;
    self.inputs = inputs;
    self.inputs_revision += 1;
}

fn recordCommand(self: *Builder, output: []const u8) !bool {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    errdefer arena.deinit();
    var lines = std.mem.splitScalar(u8, output, '\n');
    const found = while (lines.next()) |line| {
        const argv = try verboseCommand(arena.allocator(), line) orelse continue;
        const name = flagValue(argv, "--name") orelse continue;
        if (std.mem.eql(u8, name, self.artifact_name)) break argv;
    } else null;

    const argv = found orelse {
        arena.deinit();
        return false;
    };
    if (sameCommand(argv, self.command)) {
        arena.deinit();
        return false;
    }
    self.command_arena.deinit();
    self.command_arena = arena;
    self.command = argv;
    return true;
}

fn verboseCommand(allocator: std.mem.Allocator, line: []const u8) !?[]const []const u8 {
    const prefix = "info(verbose): ";
    if (!std.mem.startsWith(u8, line, prefix))
        return null;
    return command_line.parse(allocator, line[prefix.len..]);
}

fn fail(self: *Builder, allocator: std.mem.Allocator, output: []const u8, started_at: std.Io.Timestamp) !void {
    const summary = try diagnostics.summary(allocator, output);
    const message = if (summary.len == 0) "The build failed without diagnostics." else summary[0..@min(summary.len, diagnostics_max)];
    std.debug.print("{s}\n", .{message});
    self.publisher.publish(self.publisher.context, .{ .failed = message });
    log.warn("event=build_failed duration_ms={d} action=keep_last_working_app", .{elapsedMilliseconds(self.io, started_at)});
}

fn run(self: *const Builder, allocator: std.mem.Allocator, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, self.io, .{
        .argv = argv,
        .environ_map = &self.environ,
        .stdout_limit = .limited(build_output_max),
        .stderr_limit = .limited(build_output_max),
    });
}

fn watchInputs(watcher: *Watch, gpa: std.mem.Allocator, inputs: []const []const u8) void {
    var directories: std.ArrayList([]const u8) = .empty;
    defer directories.deinit(gpa);
    for (inputs) |file| {
        const directory = std.fs.path.dirname(file) orelse continue;
        for (directories.items) |known| {
            if (std.mem.eql(u8, known, directory)) break;
        } else directories.append(gpa, directory) catch return;
    }
    watcher.setDirectories(directories.items) catch |err| {
        log.warn("event=file_events_failed error={t} action=rescan interval_ms={d}", .{ err, rescan_interval_ms });
    };
}

const Compiler = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    cache: []const u8,
    name: []const u8,
    build_root: []const u8,
    child: std.process.Child,
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,
    read_buffer: [64 * 1024]u8,
    write_buffer: [64]u8,
    inputs: []const []const u8 = &.{},
    inputs_arena: std.heap.ArenaAllocator,

    const Output = union(enum) { binary: []const u8, errors: []const u8 };

    fn start(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, stored: []const []const u8) !*Compiler {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();

        const allocator = arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        for (stored) |arg| {
            if (isCompilerServerFlag(arg))
                continue;
            try argv.append(allocator, try allocator.dupe(u8, arg));
        }

        try argv.appendSlice(allocator, &.{ "--listen=-", "-fincremental" });
        const cache = flagValue(argv.items, "--cache-dir") orelse return error.CommandHasNoCacheDirectory;
        const name = flagValue(argv.items, "--name") orelse return error.CommandHasNoName;
        const build_root = flagValue(argv.items, "--build-root") orelse ".";

        const self = try gpa.create(Compiler);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .arena = arena,
            .cache = cache,
            .name = name,
            .build_root = build_root,
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
            .inputs_arena = .init(gpa),
        };
        errdefer self.child.kill(io);
        self.reader = self.child.stdout.?.readerStreaming(io, &self.read_buffer);
        self.writer = self.child.stdin.?.writerStreaming(io, &self.write_buffer);
        try self.requestUpdate();
        return self;
    }

    fn isCompilerServerFlag(arg: []const u8) bool {
        return std.mem.eql(u8, arg, "--listen=-") or
            std.mem.eql(u8, arg, "-fincremental") or
            std.mem.eql(u8, arg, "-fno-incremental");
    }

    fn stop(self: *Compiler) void {
        self.child.kill(self.io);
        const gpa = self.gpa;
        self.inputs_arena.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn update(self: *Compiler, allocator: std.mem.Allocator) !Output {
        try self.requestUpdate();
        return self.receive(allocator);
    }

    fn requestUpdate(self: *Compiler) !void {
        const header: std.zig.Client.Message.Header = .{ .tag = .update, .bytes_len = 0 };
        try self.writer.interface.writeStruct(header, .little);
        try self.writer.interface.flush();
    }

    fn receive(self: *Compiler, allocator: std.mem.Allocator) !Output {
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
                .file_system_inputs => try self.readInputs(try in.readAllocAll(allocator, header.bytes_len)),
                .error_bundle => {
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

    /// Each entry is a directory byte plus one, then a path. Only the working
    /// directory (0) and the build root (4) hold the user's files.
    fn readInputs(self: *Compiler, body: []const u8) !void {
        _ = self.inputs_arena.reset(.retain_capacity);
        const allocator = self.inputs_arena.allocator();
        var inputs: std.ArrayList([]const u8) = .empty;
        var paths = std.mem.splitScalar(u8, body, 0);
        while (paths.next()) |entry| {
            if (entry.len < 2) continue;
            const base: []const u8 = switch (entry[0] - 1) {
                0 => ".",
                4 => self.build_root,
                else => continue,
            };
            const path = entry[1..];
            if (std.fs.path.isAbsolute(path)) {
                try inputs.append(allocator, try allocator.dupe(u8, path));
                continue;
            }
            const joined = try std.fs.path.join(allocator, &.{ base, path });
            const absolute = std.Io.Dir.cwd().realPathFileAlloc(self.io, joined, allocator) catch continue;
            try inputs.append(allocator, absolute);
        }
        self.inputs = inputs.items;
    }
};

fn flagValue(argv: []const []const u8, flag: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (1..argv.len) |index| {
        if (std.mem.eql(u8, argv[index - 1], flag))
            result = argv[index];
    }
    return result;
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
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

fn elapsedMilliseconds(io: std.Io, started_at: std.Io.Timestamp) i64 {
    return started_at.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
}
