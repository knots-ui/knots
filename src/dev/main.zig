//! `zig build dev` (see `addDevWatcher` in build.zig): runs `zig build <step> --watch`
//! and, each time the build installs a new artifact, restarts the app, or
//! reloads the page of a browser app. The app is the one `zig build` installs.
//!
//! Usage: knots-dev --zig=<path> --build-file=<path> --prefix=<path> --step=<name>
//!     --artifact=<path in prefix> [--serve=<directory in prefix> --port=<port>] [--build-arg=<arg>]...
//!     [--watch-arg=<arg>]...

const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");

const log = std.log.scoped(.knots_dev);

const poll_interval_ms = 100;

const Options = struct {
    zig: []const u8 = "",
    build_file: []const u8 = "",
    prefix: []const u8 = "",
    step: []const u8 = "",
    artifact: []const u8 = "",
    serve: ?[]const u8 = null,
    port: u16 = 8000,
    build_args: []const []const u8 = &.{},
    /// Only for the `--watch` build, such as `-fincremental`.
    watch_args: []const []const u8 = &.{},

    fn parse(arena: std.mem.Allocator, args: []const []const u8) !Options {
        var options: Options = .{};
        var build_args: std.ArrayList([]const u8) = .empty;
        var watch_args: std.ArrayList([]const u8) = .empty;
        for (args) |arg| {
            const separator = std.mem.indexOfScalar(u8, arg, '=') orelse return error.ExpectedFlag;
            const name = arg[0..separator];
            const value = arg[separator + 1 ..];
            if (std.mem.eql(u8, name, "--zig")) {
                options.zig = value;
            } else if (std.mem.eql(u8, name, "--build-file")) {
                options.build_file = value;
            } else if (std.mem.eql(u8, name, "--prefix")) {
                options.prefix = value;
            } else if (std.mem.eql(u8, name, "--step")) {
                options.step = value;
            } else if (std.mem.eql(u8, name, "--artifact")) {
                options.artifact = value;
            } else if (std.mem.eql(u8, name, "--serve")) {
                options.serve = value;
            } else if (std.mem.eql(u8, name, "--port")) {
                options.port = try std.fmt.parseInt(u16, value, 10);
            } else if (std.mem.eql(u8, name, "--build-arg")) {
                try build_args.append(arena, value);
            } else if (std.mem.eql(u8, name, "--watch-arg")) {
                try watch_args.append(arena, value);
            } else return error.UnknownFlag;
        }
        for ([_][]const u8{ options.zig, options.build_file, options.prefix, options.step, options.artifact }) |value|
            if (value.len == 0) return error.MissingFlag;
        options.build_args = build_args.items;
        options.watch_args = watch_args.items;
        return options;
    }
};

const Event = union(enum) {
    installed,
    build_exited: std.process.Child.Term,
    app_exited: struct { generation: u32, term: std.process.Child.Term },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = try Options.parse(arena, args[1..]);
    const artifact = try std.fs.path.join(arena, &.{ options.prefix, options.artifact });

    // The build would report its progress to the `zig build dev` around this.
    var environ = try init.environ_map.clone(arena);
    _ = environ.swapRemove("ZIG_PROGRESS");

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ options.zig, "build", options.step, "--build-file", options.build_file, "--prefix", options.prefix });
    try argv.appendSlice(arena, options.build_args);

    // The first build finishes before the app starts, so a stale one never runs.
    var first_build = try std.process.spawn(io, .{ .argv = argv.items, .environ_map = &environ });
    const first = try first_build.wait(io);
    var installed = stamp(io, artifact);
    if (first.success() and installed == null)
        log.warn("`zig build {s}` did not install {s}", .{ options.step, artifact });

    try argv.append(arena, "--watch");
    try argv.appendSlice(arena, options.watch_args);
    var build = try std.process.spawn(io, .{ .argv = argv.items, .environ_map = &environ });
    running.build = build.id;
    stopOnSignal();

    var buffer: [8]Event = undefined;
    var events: std.Io.Queue(Event) = .init(&buffer);
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(io);
    try tasks.concurrent(io, waitBuild, .{ io, &build, &events });
    try tasks.concurrent(io, watchArtifact, .{ io, artifact, installed, &events });

    var server: ?*http.Server = null;
    if (options.serve) |directory| {
        server = try http.Server.create(init.gpa, io, try std.fs.path.join(arena, &.{ options.prefix, directory }), options.port);
        try tasks.concurrent(io, http.Server.run, .{server.?});
        log.info("serving http://localhost:{d}", .{options.port});
    }

    var app: ?std.process.Child = null;
    var generation: u32 = 0;
    if (server == null and first.success() and installed != null)
        app = try launch(io, artifact, &generation, &tasks, &events);

    while (true) switch (try events.getOne(io)) {
        .installed => {
            installed = stamp(io, artifact);
            if (server) |s| {
                s.reload();
                continue;
            }
            if (app) |*previous| terminate(previous);
            // The old app's exit is reported with an old generation.
            app = try launch(io, artifact, &generation, &tasks, &events);
        },
        .app_exited => |exit| {
            if (exit.generation != generation) continue;
            app = null;
            // Closing the app ends the session, as it would outside of `zig build dev`.
            if (exit.term.success()) break;
            log.err("the app {f}; it restarts after the next build", .{exit.term});
        },
        .build_exited => |term| {
            if (app) |*previous| terminate(previous);
            if (!term.success()) std.process.exit(1);
            return;
        },
    };
    terminate(&build);
}

fn launch(io: std.Io, path: []const u8, generation: *u32, tasks: *std.Io.Group, events: *std.Io.Queue(Event)) !std.process.Child {
    generation.* +%= 1;
    const child = try std.process.spawn(io, .{ .argv = &.{path} });
    running.app = child.id;
    // The waiting task gets its own copy, which `wait` cleans up.
    const waited = try std.heap.page_allocator.create(std.process.Child);
    waited.* = child;
    try tasks.concurrent(io, waitApp, .{ io, waited, generation.*, events });
    return child;
}

fn waitApp(io: std.Io, child: *std.process.Child, generation: u32, events: *std.Io.Queue(Event)) void {
    defer std.heap.page_allocator.destroy(child);
    const term = child.wait(io) catch return;
    events.putOneUncancelable(io, .{ .app_exited = .{ .generation = generation, .term = term } }) catch {};
}

fn waitBuild(io: std.Io, child: *std.process.Child, events: *std.Io.Queue(Event)) void {
    const term = child.wait(io) catch return;
    events.putOneUncancelable(io, .{ .build_exited = term }) catch {};
}

/// Installs replace the file, so a new stamp means that a build finished.
fn watchArtifact(io: std.Io, path: []const u8, initial: ?Stamp, events: *std.Io.Queue(Event)) std.Io.Cancelable!void {
    var last = initial;
    while (true) {
        try io.sleep(.fromMilliseconds(poll_interval_ms), .awake);
        const current = stamp(io, path) orelse continue;
        if (last != null and std.meta.eql(current, last.?)) continue;
        last = current;
        events.putOne(io, .installed) catch |err| switch (err) {
            error.Closed => return,
            error.Canceled => |e| return e,
        };
    }
}

const Stamp = struct { inode: std.Io.File.INode, size: u64, mtime: i96 };

fn stamp(io: std.Io, path: []const u8) ?Stamp {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds };
}

/// What a signal stops along with this process. A terminal's Ctrl+C reaches
/// them anyway; another `kill` would leave them running.
var running: struct { build: ?std.process.Child.Id = null, app: ?std.process.Child.Id = null } = .{};

fn stopOnSignal() void {
    if (builtin.os.tag == .windows) return;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    for ([_]?std.process.Child.Id{ running.app, running.build }) |id|
        if (id) |pid| std.posix.kill(pid, .TERM) catch {};
    std.process.exit(1);
}

/// Asks the process to stop; the task waiting on it reports the exit.
fn terminate(child: *const std.process.Child) void {
    const id = child.id orelse return;
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(id, .SUCCESS);
    } else std.posix.kill(id, .TERM) catch {};
}
