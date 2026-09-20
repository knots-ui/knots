const std = @import("std");
const celer = @import("celer");

const file_bytes_max = 256 * 1024 * 1024;
const headers: []const std.http.Header = &.{
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
    .{ .name = "cross-origin-embedder-policy", .value = "require-corp" },
};

var directory_path: []const u8 = "";
var hmr_directory_path: []const u8 = "";
var host_module_path: []const u8 = "";
var events_state: ?*Events = null;
var server_io: ?std.Io = null;

const Events = struct {
    condition: std.Io.Condition = .init,
    mutex: std.Io.Mutex = .init,
    revision: u64 = 1,

    fn publish(events: *Events, io: std.Io) void {
        events.mutex.lockUncancelable(io);
        events.revision +%= 1;
        if (events.revision == 0) events.revision = 1;
        std.debug.assert(events.revision > 0);
        events.condition.broadcast(io);
        events.mutex.unlock(io);
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.ExpectedDirectoryHmrDirectoryPortAndHostModule;
    const port = try std.fmt.parseInt(u16, args[3], 10);

    directory_path = args[1];
    hmr_directory_path = args[2];
    host_module_path = args[4];
    std.debug.assert(directory_path.len > 0);
    std.debug.assert(hmr_directory_path.len > 0);
    std.debug.assert(host_module_path.len > 0);

    var events: Events = .{};
    events_state = &events;
    defer events_state = null;
    server_io = init.io;
    defer server_io = null;
    var tasks: std.Io.Group = .init;
    defer tasks.cancel(init.io);
    try tasks.concurrent(init.io, readEvents, .{ init.io, &events });

    var server = try celer.Server.init(.{ .route_fn = route }, .{
        .port = port,
        .host = .localhost,
        .read_buffer_size = 16 * 1024,
        .write_buffer_size = 16 * 1024,
        .kernel_backlog = 128,
        .before_fn = null,
        .ws_handler = null,
    }, init.gpa);
    defer server.deinit();
    std.log.info("event=web_server_ready url=http://localhost:{d}", .{port});
    try server.start(init.io, init.gpa);
}

fn readEvents(io: std.Io, events: *Events) void {
    var buffer: [64]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
    const expected = "change\n";
    while (true) {
        var index: usize = 0;
        while (index < expected.len) : (index += 1) {
            const byte = reader.interface.takeByte() catch return;
            if (byte != expected[index]) return;
        }
        std.debug.assert(index == expected.len);
        events.publish(io);
    }
}

fn route(server: *celer.Server, allocator: std.mem.Allocator, request: *celer.Request) !void {
    std.debug.assert(events_state != null);
    std.debug.assert(server_io != null);
    std.debug.assert(directory_path.len > 0);
    std.debug.assert(hmr_directory_path.len > 0);
    std.debug.assert(server.cfg.port > 0);

    switch (request.req.head.method) {
        .GET, .HEAD => {},
        else => {
            try request.respond(.{
                .body = "Method not allowed.\n",
                .options = .{ .status = .method_not_allowed, .keep_alive = false, .extra_headers = headers },
            });
            return;
        },
    }

    const request_target = request.req.head.target;
    const target = request_target[0 .. std.mem.indexOfScalar(u8, request_target, '?') orelse request_target.len];
    if (std.mem.eql(u8, target, "/hmr/events")) {
        try serveEvents(server_io.?, request, events_state.?);
        return;
    }
    if (std.mem.eql(u8, target, "/hmr")) {
        try serveFile(allocator, server_io.?, request, hmr_directory_path, "/");
        return;
    }
    if (std.mem.startsWith(u8, target, "/hmr/")) {
        try serveFile(allocator, server_io.?, request, hmr_directory_path, target[4..]);
        return;
    }
    if (std.mem.eql(u8, request_target, host_module_path)) {
        const location = try std.fmt.allocPrint(allocator, "{s}?knots-hmr", .{host_module_path});
        const redirect_headers: []const std.http.Header = &.{.{ .name = "location", .value = location }};
        try request.respond(.{
            .body = "",
            .options = .{ .status = .temporary_redirect, .keep_alive = request.req.head.keep_alive, .extra_headers = redirect_headers },
        });
        return;
    }
    try serveFile(allocator, server_io.?, request, directory_path, target);
}

fn serveEvents(io: std.Io, request: *celer.Request, events: *Events) !void {
    std.debug.assert(server_io != null);
    std.debug.assert(events.revision > 0);
    var buffer: [256]u8 = undefined;
    const response_headers: []const std.http.Header = &.{
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
        .{ .name = "cross-origin-embedder-policy", .value = "require-corp" },
        .{ .name = "content-type", .value = "text/event-stream" },
    };
    var body = try request.respondStreaming(&buffer, .{ .respond_options = .{ .keep_alive = true, .extra_headers = response_headers } });
    var revision: u64 = 0;
    while (true) {
        events.mutex.lockUncancelable(io);
        while (events.revision == revision) {
            events.condition.waitTimeout(io, &events.mutex, .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(15), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => break,
                error.Canceled => return err,
            };
        }
        const next_revision = events.revision;
        events.mutex.unlock(io);
        if (next_revision > revision) {
            revision = next_revision;
            try body.writer.print("event: change\ndata: {d}\n\n", .{revision});
        } else {
            try body.writer.writeAll(": keepalive\n\n");
        }
        try body.writer.flush();
        try body.flush();
    }
}

fn serveFile(allocator: std.mem.Allocator, io: std.Io, request: *celer.Request, directory: []const u8, target: []const u8) !void {
    std.debug.assert(server_io != null);
    std.debug.assert(directory.len > 0);
    std.debug.assert(target.len > 0);
    if (!validTarget(target)) {
        try request.respond(.{ .body = "Bad request.\n", .options = .{ .status = .bad_request, .extra_headers = headers } });
        return;
    }
    const relative = if (std.mem.eql(u8, target, "/")) "index.html" else target[1..];
    const path = try std.fs.path.join(allocator, &.{ directory, relative });
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(file_bytes_max)) catch |err| {
        const status: std.http.Status = if (err == error.FileNotFound) .not_found else .internal_server_error;
        try request.respond(.{
            .body = if (status == .not_found) "Not found.\n" else "Read failed.\n",
            .options = .{ .status = status, .extra_headers = headers },
        });
        return;
    };
    defer allocator.free(bytes);
    const response_headers: [4]std.http.Header = .{
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
        .{ .name = "cross-origin-embedder-policy", .value = "require-corp" },
        .{ .name = "content-type", .value = contentType(relative) },
    };
    try request.respond(.{ .body = bytes, .options = .{ .extra_headers = &response_headers } });
}

fn validTarget(target: []const u8) bool {
    if (target.len == 0) return false;
    if (target[0] != '/') return false;
    if (target.len > 1) {
        if (target[1] == '/') return false;
    }
    if (std.mem.indexOf(u8, target, "..") != null) return false;
    if (std.mem.indexOfScalar(u8, target, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, target, ':') != null) return false;
    std.debug.assert(target[0] == '/');
    std.debug.assert(std.mem.indexOf(u8, target, "..") == null);
    return true;
}

fn contentType(path: []const u8) []const u8 {
    std.debug.assert(path.len > 0);
    const extension = std.fs.path.extension(path);
    if (std.mem.eql(u8, extension, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, extension, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.eql(u8, extension, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, extension, ".json")) return "application/json";
    return "application/octet-stream";
}
