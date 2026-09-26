const std = @import("std");
const celer = @import("celer");

const file_bytes_max = 256 * 1024 * 1024;
const headers: []const std.http.Header = &.{
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
    .{ .name = "cross-origin-embedder-policy", .value = "require-corp" },
};

pub const Config = struct {
    web_directory: ?[]const u8,
    hmr_directory: []const u8,
    host_module_path: ?[]const u8,
    port: u16,
};

var config: ?Config = null;
var events_state: ?*Events = null;
var server_io: ?std.Io = null;

pub const Events = struct {
    condition: std.Io.Condition = .init,
    mutex: std.Io.Mutex = .init,
    revision: u64 = 1,

    pub fn publish(events: *Events, io: std.Io) void {
        events.mutex.lockUncancelable(io);
        events.revision +%= 1;
        if (events.revision == 0) events.revision = 1;
        std.debug.assert(events.revision > 0);
        events.condition.broadcast(io);
        events.mutex.unlock(io);
    }
};

pub fn serve(io: std.Io, allocator: std.mem.Allocator, configuration: Config, events: *Events) !void {
    std.debug.assert(configuration.port > 0);
    std.debug.assert(configuration.hmr_directory.len > 0);
    if (configuration.web_directory) |directory| {
        std.debug.assert(directory.len > 0);
        std.debug.assert(configuration.host_module_path != null);
    } else {
        std.debug.assert(configuration.host_module_path == null);
    }
    if (configuration.host_module_path) |path| std.debug.assert(path.len > 0);
    std.debug.assert(config == null);
    std.debug.assert(events_state == null);
    std.debug.assert(server_io == null);
    config = configuration;
    events_state = events;
    defer config = null;
    defer events_state = null;
    server_io = io;
    defer server_io = null;

    var server = try celer.Server.init(.{ .route_fn = route }, .{
        .port = configuration.port,
        .host = .localhost,
        .read_buffer_size = 16 * 1024,
        .write_buffer_size = 16 * 1024,
        .kernel_backlog = 128,
        .before_fn = null,
        .ws_handler = null,
    }, allocator);
    defer server.deinit();
    std.log.info("event=http_server_starting url=http://127.0.0.1:{d}", .{configuration.port});
    try server.start(io, allocator);
}

fn route(server: *celer.Server, allocator: std.mem.Allocator, request: *celer.Request) !void {
    const configuration = config orelse return error.HttpServerNotConfigured;
    std.debug.assert(events_state != null);
    std.debug.assert(server_io != null);
    std.debug.assert(configuration.hmr_directory.len > 0);
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
        try serveFile(allocator, server_io.?, request, configuration.hmr_directory, "/");
        return;
    }
    if (std.mem.startsWith(u8, target, "/hmr/")) {
        try serveFile(allocator, server_io.?, request, configuration.hmr_directory, target[4..]);
        return;
    }
    if (configuration.host_module_path) |host_module_path| {
        if (std.mem.eql(u8, request_target, host_module_path)) {
            const location = try std.fmt.allocPrint(allocator, "{s}?knots-hmr", .{host_module_path});
            const redirect_headers: []const std.http.Header = &.{.{ .name = "location", .value = location }};
            try request.respond(.{
                .body = "",
                .options = .{ .status = .temporary_redirect, .keep_alive = request.req.head.keep_alive, .extra_headers = redirect_headers },
            });
            return;
        }
    }
    if (configuration.web_directory) |directory| {
        try serveFile(allocator, server_io.?, request, directory, target);
        return;
    }
    try request.respond(.{ .body = "Not found.\n", .options = .{ .status = .not_found, .extra_headers = headers } });
}

fn serveEvents(io: std.Io, request: *celer.Request, events: *Events) !void {
    std.debug.assert(server_io != null);
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
                error.Canceled => {
                    events.mutex.unlock(io);
                    return err;
                },
            };
        }
        const next_revision = events.revision;
        events.mutex.unlock(io);
        if (next_revision != revision) {
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
