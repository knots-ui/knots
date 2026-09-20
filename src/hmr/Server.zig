const std = @import("std");
const Discovery = @import("Discovery.zig");
const Protocol = @import("Protocol.zig");
const Status = @import("Status.zig");
const Artifact = @import("Artifact.zig");
const Log = @import("Log.zig");
const Watch = @import("watch");

pub const std_options: std.Options = .{ .logFn = log };

const application_check_interval_ms: u64 = 1_000;
const build_stream_max: usize = 256 * 1024;

comptime {
    std.debug.assert(application_check_interval_ms > 0);
    std.debug.assert(application_check_interval_ms <= 1_000);
}

const Configuration = struct {
    roots: []const []const u8,
    watch_roots: []const []const u8,
    watch_root: []const u8,
};

const BuildPhase = enum { initial, reload };

const Application = struct {
    done: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    events: bool,
    input: ?std.Io.File = null,
    mutex: std.Io.Mutex = .init,

    fn notify(state: *Application, io: std.Io) void {
        std.debug.assert(state.events);
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        const input = state.input orelse return;
        input.writeStreamingAll(io, "change\n") catch |err| {
            std.log.warn("event=application_notification_failed error={s}", .{@errorName(err)});
        };
    }
};

const BuildResult = struct {
    term: std.process.Child.Term,
    diagnostics: []const u8,
};

var interrupted: std.atomic.Value(bool) = .init(false);

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 8) {
        std.log.err("event=server_configuration_failed reason=expected_arguments minimum=8 actual={d}", .{boundedCount(args.len)});
        return error.ExpectedConfiguration;
    }

    try std.Io.Dir.cwd().createDirPath(init.io, args[5]);
    const prefix = try std.Io.Dir.cwd().realPathFileAlloc(init.io, args[5], allocator);
    try std.Io.Dir.cwd().createDirPath(init.io, try std.fs.path.join(allocator, &.{ prefix, "hmr" }));
    const status_path = try std.fs.path.resolve(allocator, &.{ prefix, "hmr/status.json" });

    const lock_path = try std.fs.path.join(allocator, &.{ prefix, "hmr/server.lock" });
    const lock = try std.Io.Dir.cwd().createFile(init.io, lock_path, .{ .truncate = false });
    defer lock.close(init.io);

    if (!try lock.tryLock(init.io, .exclusive)) {
        std.log.err("event=server_configuration_failed reason=session_already_running lock=\"{f}\"", .{std.zig.fmtString(lock_path)});
        return error.HmrSessionAlreadyRunning;
    }
    defer lock.unlock(init.io);

    const config_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(Protocol.bytes_max));
    const config = try std.json.parseFromSlice(Configuration, allocator, config_bytes, .{ .allocate = .alloc_always });

    const application_events = std.mem.eql(u8, args[6], "events");
    if (!application_events) {
        if (!std.mem.eql(u8, args[6], "no-events")) return error.ExpectedApplicationEventMode;
    }

    var separator: usize = 7;
    while (separator < args.len) : (separator += 1) {
        if (std.mem.eql(u8, args[separator], "--")) break;
    }

    if (separator == args.len) {
        std.log.err("event=server_configuration_failed reason=missing_separator", .{});
        return error.ExpectedSeparator;
    }

    var build: std.ArrayList([]const u8) = .empty;
    try build.appendSlice(allocator, &.{ args[2], "build", "knots-hmr-modules", "--build-file", args[3], "--prefix", prefix });
    try build.appendSlice(allocator, args[7..separator]);

    var app: std.ArrayList([]const u8) = .empty;
    try app.append(allocator, args[4]);
    try app.appendSlice(allocator, args[separator + 1 ..]);
    if (@import("builtin").os.tag != .windows) {
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = signal }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.INT, &action, null);
        std.posix.sigaction(.TERM, &action, null);
    }

    var snapshot: [32]u8 = undefined;
    var initial_module_count: u32 = 0;
    {
        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();
        const scan_started_at = std.Io.Clock.awake.now(init.io);
        snapshot = Discovery.fingerprint(arena.allocator(), init.io, config.value.watch_roots) catch |err| {
            std.log.err("event=source_scan_failed phase=initial error={s} duration_ms={d}", .{ @errorName(err), Log.elapsedMilliseconds(init.io, scan_started_at) });
            return err;
        };
        const result = try rebuild(arena.allocator(), init.io, prefix, build.items, .initial);
        if (!result.term.success()) {
            writeBuildErrorStatus(arena.allocator(), init.io, status_path, .initial, result.diagnostics) catch |err| {
                std.log.err("event=status_write_failed phase=initial error={s}", .{@errorName(err)});
            };
            return error.HmrBuildFailed;
        }
        const publication_started_at = std.Io.Clock.awake.now(init.io);
        initial_module_count = publish(arena.allocator(), init.io, prefix, &config.value, .initial) catch |err| {
            std.log.err("event=publication_failed phase=initial error={s} duration_ms={d}", .{ @errorName(err), Log.elapsedMilliseconds(init.io, publication_started_at) });
            return err;
        };
        try writeReadyStatus(arena.allocator(), init.io, status_path, .initial);
    }

    const manifest_path = try std.fs.path.resolve(allocator, &.{ prefix, "hmr/manifest.json" });
    try init.environ_map.put("KNOTS_HMR_MANIFEST", manifest_path);
    try init.environ_map.put("KNOTS_HMR_STATUS", status_path);
    std.log.info("event=server_ready modules={d}", .{initial_module_count});

    var state: Application = .{ .events = application_events };
    var watcher = try Watch.init(init.io, init.gpa, &interrupted, config.value.watch_root);
    defer watcher.deinit();
    var children: std.Io.Group = .init;
    defer children.cancel(init.io);
    try children.concurrent(init.io, runApplication, .{ init.io, app.items, init.environ_map, &state });
    while (!interrupted.load(.acquire)) {
        if (state.done.load(.acquire)) {
            if (state.failed.load(.acquire)) {
                std.log.err("event=server_stopped reason=application_failed", .{});
                return error.ApplicationFailed;
            }
            return;
        }

        if (watcher.wait(application_check_interval_ms) == .timeout) continue;
        if (watcher.changedPath()) |path| {
            std.log.info("event=source_changed path=\"{f}\" action=scan_for_hmr_changes", .{std.zig.fmtString(path)});
        } else {
            std.log.info("event=source_changed path=unknown action=scan_for_hmr_changes", .{});
        }

        var arena = std.heap.ArenaAllocator.init(init.gpa);
        defer arena.deinit();

        const scan_started_at = std.Io.Clock.awake.now(init.io);
        const current = Discovery.fingerprint(arena.allocator(), init.io, config.value.watch_roots) catch |err| {
            std.log.warn("event=source_scan_failed phase=watch error={s} duration_ms={d} action=retain_current_modules", .{ @errorName(err), Log.elapsedMilliseconds(init.io, scan_started_at) });
            continue;
        };

        if (std.mem.eql(u8, &snapshot, &current))
            continue;

        snapshot = current;
        const result = rebuild(arena.allocator(), init.io, prefix, build.items, .reload) catch |err| {
            const message = try std.fmt.allocPrint(arena.allocator(), "HMR rebuild could not start: {s}", .{@errorName(err)});
            writeErrorStatus(arena.allocator(), init.io, status_path, Status.kind_error, "reload", message) catch |status_err| {
                std.log.err("event=status_write_failed phase=reload error={s}", .{@errorName(status_err)});
            };
            if (state.events) state.notify(init.io);
            continue;
        };
        if (!result.term.success()) {
            writeBuildErrorStatus(arena.allocator(), init.io, status_path, .reload, result.diagnostics) catch |err| {
                std.log.err("event=status_write_failed phase=reload error={s}", .{@errorName(err)});
            };
            if (state.events) state.notify(init.io);
            continue;
        }
        const publication_started_at = std.Io.Clock.awake.now(init.io);
        _ = publish(arena.allocator(), init.io, prefix, &config.value, .reload) catch |err| {
            std.log.warn("event=publication_failed phase=reload error={s} duration_ms={d} action=retain_previous_manifest", .{ @errorName(err), Log.elapsedMilliseconds(init.io, publication_started_at) });
            const message = std.fmt.allocPrint(arena.allocator(), "HMR update could not be published: {s}", .{@errorName(err)}) catch "HMR update could not be published.";
            writeErrorStatus(arena.allocator(), init.io, status_path, Status.kind_error, "reload", message) catch |status_err| {
                std.log.err("event=status_write_failed phase=reload error={s}", .{@errorName(status_err)});
            };
            if (state.events) state.notify(init.io);
            continue;
        };
        writeReadyStatus(arena.allocator(), init.io, status_path, .reload) catch |err| {
            std.log.err("event=status_write_failed phase=reload error={s}", .{@errorName(err)});
        };
        if (state.events) state.notify(init.io);
    }

    std.log.info("event=server_stopped reason=signal", .{});
}

fn signal(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

fn runApplication(io: std.Io, args: []const []const u8, environment: *const std.process.Environ.Map, state: *Application) void {
    defer state.done.store(true, .release);

    std.debug.assert(args.len > 0);
    const started_at = std.Io.Clock.awake.now(io);

    var child = std.process.spawn(io, .{ .argv = args, .environ_map = environment, .stdin = if (state.events) .pipe else .inherit, .stdout = .inherit, .stderr = .inherit, .expand_arg0 = .no_expand }) catch |err| {
        std.log.err("event=application_start_failed error={s} duration_ms={d}", .{ @errorName(err), Log.elapsedMilliseconds(io, started_at) });
        state.failed.store(true, .release);
        return;
    };
    defer child.kill(io);
    if (state.events) {
        state.mutex.lockUncancelable(io);
        std.debug.assert(state.input == null);
        std.debug.assert(child.stdin != null);
        state.input = child.stdin;
        child.stdin = null;
        state.mutex.unlock(io);
    } else {
        std.debug.assert(state.input == null);
        std.debug.assert(child.stdin == null);
    }
    defer if (state.events) {
        state.mutex.lockUncancelable(io);
        const input = state.input.?;
        state.input = null;
        input.close(io);
        state.mutex.unlock(io);
    };
    const id = child.id;
    const result = child.wait(io) catch |err| {
        child.id = id;
        if (err == error.Canceled) {
            std.log.info("event=application_stopped reason=server_shutdown duration_ms={d}", .{Log.elapsedMilliseconds(io, started_at)});
        } else {
            std.log.err("event=application_wait_failed error={s} duration_ms={d}", .{ @errorName(err), Log.elapsedMilliseconds(io, started_at) });
        }
        state.failed.store(true, .release);
        return;
    };

    const duration_ms = Log.elapsedMilliseconds(io, started_at);
    switch (result) {
        .exited => |code| {
            if (code != 0) {
                std.log.err("event=application_stopped status=failed exit_code={d} duration_ms={d}", .{ code, duration_ms });
            }
            state.failed.store(code != 0, .release);
        },
        .signal => |signal_number| {
            std.log.err("event=application_stopped status=signal signal={t} duration_ms={d}", .{ signal_number, duration_ms });
            state.failed.store(true, .release);
        },
        .stopped => |signal_number| {
            std.log.err("event=application_stopped status=stopped signal={t} duration_ms={d}", .{ signal_number, duration_ms });
            state.failed.store(true, .release);
        },
        .unknown => |status| {
            std.log.err("event=application_stopped status=unknown value={d} duration_ms={d}", .{ status, duration_ms });
            state.failed.store(true, .release);
        },
    }
}

fn rebuild(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8, arguments: []const []const u8, phase: BuildPhase) !BuildResult {
    // Only successful installs from this attempt may enter the next manifest.
    std.debug.assert(arguments.len > 0);
    const started_at = std.Io.Clock.awake.now(io);
    const staging = try std.fs.path.join(allocator, &.{ prefix, "hmr/staging" });
    std.Io.Dir.cwd().deleteTree(io, staging) catch |err| {
        std.log.err("event=build_staging_cleanup_failed phase={t} error={s} duration_ms={d}", .{ phase, @errorName(err), Log.elapsedMilliseconds(io, started_at) });
        return err;
    };
    const result = std.process.run(allocator, io, .{
        .argv = arguments,
        .stderr_limit = .limited(build_stream_max),
        .stdout_limit = .limited(build_stream_max),
        .reserve_amount = 1024,
        .expand_arg0 = .no_expand,
        .create_no_window = false,
        .disable_aslr = false,
        .timeout = .none,
    }) catch |err| {
        std.log.err("event=build_start_failed phase={t} error={s} duration_ms={d}", .{ phase, @errorName(err), Log.elapsedMilliseconds(io, started_at) });
        return err;
    };
    const duration_ms = Log.elapsedMilliseconds(io, started_at);
    const diagnostics = if (result.stderr.len > 0) result.stderr else result.stdout;
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                printBuildDiagnostics(diagnostics);
                std.log.warn("event=build_finished phase={t} status=failed exit_code={d} diagnostics_bytes={d} duration_ms={d} action=retain_previous_artifacts", .{ phase, code, boundedCount(diagnostics.len), duration_ms });
            }
        },
        .signal => |signal_number| {
            printBuildDiagnostics(diagnostics);
            std.log.warn("event=build_finished phase={t} status=signal signal={t} diagnostics_bytes={d} duration_ms={d} action=retain_previous_artifacts", .{ phase, signal_number, boundedCount(diagnostics.len), duration_ms });
        },
        .stopped => |signal_number| {
            printBuildDiagnostics(diagnostics);
            std.log.warn("event=build_finished phase={t} status=stopped signal={t} diagnostics_bytes={d} duration_ms={d} action=retain_previous_artifacts", .{ phase, signal_number, boundedCount(diagnostics.len), duration_ms });
        },
        .unknown => |status| {
            printBuildDiagnostics(diagnostics);
            std.log.warn("event=build_finished phase={t} status=unknown value={d} diagnostics_bytes={d} duration_ms={d} action=retain_previous_artifacts", .{ phase, status, boundedCount(diagnostics.len), duration_ms });
        },
    }
    return .{ .term = result.term, .diagnostics = diagnostics };
}

fn publish(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8, config: *const Configuration, phase: BuildPhase) !u32 {
    std.debug.assert(prefix.len > 0);
    std.debug.assert(config.roots.len > 0);
    const started_at = std.Io.Clock.awake.now(io);
    const files = try Discovery.scan(allocator, io, config.roots);
    std.debug.assert(files.len <= Discovery.files_max);
    const directory = try std.fs.path.join(allocator, &.{ prefix, "hmr/artifacts" });

    try std.Io.Dir.cwd().createDirPath(io, directory);
    const manifest_path = try std.fs.path.join(allocator, &.{ prefix, "hmr/manifest.json" });

    const old_bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(Protocol.bytes_max)) catch |err| switch (err) {
        error.FileNotFound => "{\"modules\":[]}",
        else => return err,
    };

    const old = try std.json.parseFromSlice(Protocol.Manifest, allocator, old_bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false });
    var entries: std.ArrayList(Protocol.Entry) = .empty;
    var added_modules: u32 = 0;
    var changed_modules: u32 = 0;
    var removed_modules: u32 = 0;
    var retained_modules: u32 = 0;
    var missing_artifacts: u32 = 0;
    var skipped_helpers: u32 = 0;
    for (files) |file| {
        const stage = try std.fmt.allocPrint(allocator, "{s}/hmr/staging/{s}.wasm", .{ prefix, file.id });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, stage, allocator, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                var retained = false;
                for (old.value.modules) |entry| {
                    if (std.mem.eql(u8, entry.id, file.id)) {
                        try entries.append(allocator, entry);
                        retained_modules += 1;
                        retained = true;
                        break;
                    }
                }
                if (!retained) {
                    missing_artifacts += 1;
                }
                continue;
            },
            else => return err,
        };
        if (try Artifact.kind(bytes) == .helper) {
            skipped_helpers += 1;
            continue;
        }
        if (entries.items.len == Protocol.modules_max) return error.TooManyModules;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hash = try allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.wasm", .{ directory, hash });
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| {} else |_| {
            try atomicWrite(allocator, io, path, bytes);
        }
        var previous_hash: ?[]const u8 = null;
        for (old.value.modules) |entry| {
            if (std.mem.eql(u8, entry.id, file.id)) {
                previous_hash = entry.hash;
                break;
            }
        }
        if (previous_hash) |value| {
            if (!std.mem.eql(u8, value, hash)) {
                changed_modules += 1;
            }
        } else {
            added_modules += 1;
        }
        try entries.append(allocator, .{ .id = file.id, .path = path, .hash = hash });
    }
    if (entries.items.len > Protocol.modules_max) return error.TooManyModules;
    for (old.value.modules) |previous| {
        var present = false;
        for (entries.items) |entry| {
            if (std.mem.eql(u8, entry.id, previous.id)) {
                present = true;
                break;
            }
        }
        if (!present) {
            removed_modules += 1;
        }
    }
    const manifest = try std.json.Stringify.valueAlloc(allocator, Protocol.Manifest{ .modules = entries.items }, .{});
    const path = try std.fs.path.join(allocator, &.{ prefix, "hmr/manifest.json" });
    try atomicWrite(allocator, io, path, manifest);
    if (phase == .reload) {
        std.log.info(
            "event=hmr_published modules={d} added={d} changed={d} removed={d} retained={d} missing={d} helpers={d} duration_ms={d}",
            .{
                boundedCount(entries.items.len),
                added_modules,
                changed_modules,
                removed_modules,
                retained_modules,
                missing_artifacts,
                skipped_helpers,
                Log.elapsedMilliseconds(io, started_at),
            },
        );
    }
    return boundedCount(entries.items.len);
}

fn writeReadyStatus(allocator: std.mem.Allocator, io: std.Io, path: []const u8, phase: BuildPhase) !void {
    std.debug.assert(path.len > 0);
    return writeStatus(allocator, io, path, .{ .kind = Status.kind_ready, .phase = @tagName(phase) });
}

fn writeBuildErrorStatus(allocator: std.mem.Allocator, io: std.Io, path: []const u8, phase: BuildPhase, diagnostics: []const u8) !void {
    std.debug.assert(path.len > 0);
    const message = if (diagnostics.len == 0) "The HMR build failed without compiler diagnostics." else diagnostics[0..@min(diagnostics.len, Status.message_max)];
    return writeErrorStatus(allocator, io, path, Status.kind_compile_error, @tagName(phase), message);
}

fn writeErrorStatus(allocator: std.mem.Allocator, io: std.Io, path: []const u8, kind: []const u8, phase: []const u8, message: []const u8) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(kind.len > 0);
    std.debug.assert(phase.len > 0);
    const value: Status.Value = .{ .kind = kind, .phase = phase, .message = message[0..@min(message.len, Status.message_max)] };
    return writeStatus(allocator, io, path, value);
}

fn writeStatus(allocator: std.mem.Allocator, io: std.Io, path: []const u8, value: Status.Value) !void {
    std.debug.assert(path.len > 0);
    if (!Status.valid(&value)) return error.InvalidHmrStatus;
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    if (bytes.len == 0) return error.EmptyHmrStatus;
    if (bytes.len > Status.bytes_max) return error.HmrStatusTooLong;
    try atomicWrite(allocator, io, path, bytes);
}

fn printBuildDiagnostics(diagnostics: []const u8) void {
    const length = @min(diagnostics.len, Status.message_max);
    if (length > 0) std.debug.print("{s}", .{diagnostics[0..length]});
    if (length < diagnostics.len) {
        std.debug.print("\n[HMR diagnostics truncated]\n", .{});
    } else if (length > 0 and diagnostics[length - 1] != '\n') {
        std.debug.print("\n", .{});
    }
}

fn boundedCount(value: usize) u32 {
    std.debug.assert(value <= std.math.maxInt(u32));
    const result: u32 = @intCast(value);
    std.debug.assert(@as(usize, result) == value);
    return result;
}

fn atomicWrite(allocator: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = bytes, .flags = .{} });
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
}

fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = std.Options.debug_io;
    const previous_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous_cancel_protection);

    var buffer: [512]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();

    var message_buffer: [2048]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buffer, format, args) catch "log formatting failed";

    var body_buffer: [4096]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buffer, "ts={f} component=hmr-server {s}", .{ Log.timestamp(io), message }) catch return;
    std.log.defaultLogFileTerminal(level, scope, "{s}", .{body}, stderr) catch {};
}
