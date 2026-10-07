const std = @import("std");
const Builder = @import("Builder.zig");
const Events = @import("Events.zig");
const protocol = @import("protocol.zig");
const http_server = @import("http_server.zig");

const log = std.log.scoped(.hmr_server);

var stopped: std.atomic.Value(bool) = .init(false);
var failed: std.atomic.Value(bool) = .init(false);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var options: Builder.Options = .{};
    var http: http_server.Config = .{ .web_directory = "", .hmr_directory = "", .host_module_path = "", .port = 8000 };
    for (try options.parse(allocator, args[1..])) |arg| {
        const separator = std.mem.indexOfScalar(u8, arg, '=') orelse return error.ExpectedFlag;
        const value = arg[separator + 1 ..];
        if (std.mem.eql(u8, arg[0..separator], "--web-dir")) {
            http.web_directory = value;
        } else if (std.mem.eql(u8, arg[0..separator], "--host-module")) {
            http.host_module_path = value;
        } else if (std.mem.eql(u8, arg[0..separator], "--port")) {
            http.port = try std.fmt.parseInt(u16, value, 10);
        } else return error.UnknownFlag;
    }

    var publisher: Publisher = .{ .io = io, .gpa = init.gpa };
    const builder = try Builder.init(io, init.gpa, init.environ_map, options, .{ .context = &publisher, .publish = Publisher.publish });
    defer builder.deinit();
    publisher.directory = builder.directory;
    http.hmr_directory = builder.directory;
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ builder.directory, "artifacts" }));
    try builder.start();

    if (@import("builtin").os.tag != .windows) {
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.INT, &action, null);
        std.posix.sigaction(.TERM, &action, null);
    }

    var tasks: std.Io.Group = .init;
    defer tasks.cancel(io);
    try tasks.concurrent(io, serveHttp, .{ io, init.gpa, http, &publisher.events });
    log.info("event=serving url=http://127.0.0.1:{d}", .{http.port});
    builder.watch(&stopped);
    if (failed.load(.acquire)) return error.HttpServerFailed;
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    stopped.store(true, .release);
}

fn serveHttp(io: std.Io, gpa: std.mem.Allocator, config: http_server.Config, events: *Events) void {
    defer stopped.store(true, .release);
    http_server.serve(io, gpa, config, events) catch |err| {
        if (err == error.Canceled) return;
        log.err("event=http_server_failed error={t}", .{err});
    };
    failed.store(true, .release);
}

const Publisher = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    directory: []const u8 = "",
    events: Events = .{},
    published: ?[16]u8 = null,

    fn publish(context: *anyopaque, result: Builder.Result) void {
        const self: *Publisher = @ptrCast(@alignCast(context));
        self.write(result) catch |err| log.err("event=publish_failed error={t}", .{err});
        self.events.publish(self.io);
    }

    fn write(self: *Publisher, result: Builder.Result) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const allocator = arena.allocator();
        const cwd = std.Io.Dir.cwd();
        if (result == .app) {
            const hash = protocol.contentHash(result.app);
            const artifact = try std.fmt.allocPrint(allocator, "{s}/artifacts/{s}.wasm", .{ self.directory, &hash });
            // Artifacts are named by content, so an existing one is current.
            cwd.access(self.io, artifact, .{}) catch try atomicWrite(allocator, self.io, artifact, result.app);
            self.published = hash;
            try self.prune(allocator);
        }
        const manifest: protocol.Manifest = .{
            .app = if (self.published) |*hash| hash else null,
            .build_error = if (result == .failed) result.failed else null,
        };
        const bytes = try std.json.Stringify.valueAlloc(allocator, manifest, .{});
        try atomicWrite(allocator, self.io, try std.fs.path.join(allocator, &.{ self.directory, "manifest.json" }), bytes);
    }

    fn prune(self: *Publisher, allocator: std.mem.Allocator) !void {
        var artifacts = try std.Io.Dir.cwd().openDir(self.io, try std.fs.path.join(allocator, &.{ self.directory, "artifacts" }), .{ .iterate = true });
        defer artifacts.close(self.io);
        var stale: std.ArrayList([]const u8) = .empty;
        var iterator = artifacts.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (std.mem.eql(u8, std.fs.path.stem(entry.name), &self.published.?)) continue;
            try stale.append(allocator, try allocator.dupe(u8, entry.name));
        }
        for (stale.items) |name| artifacts.deleteFile(self.io, name) catch {};
    }
};

fn atomicWrite(allocator: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temporary, .data = bytes, .flags = .{} });
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
}
