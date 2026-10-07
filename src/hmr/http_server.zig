const std = @import("std");
const celer = @import("celer");
const Events = @import("Events.zig");

const file_bytes_max = 256 * 1024 * 1024;
const keepalive_seconds = 15;

// Cross-origin isolation is necessary for shared-memory threads.
const headers: []const std.http.Header = &.{
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
    .{ .name = "cross-origin-embedder-policy", .value = "require-corp" },
};

pub const Config = struct {
    web_directory: []const u8,
    hmr_directory: []const u8,
    host_module_path: []const u8,
    port: u16,
};

// celer routes get no context argument, so the state is global.
var state: ?struct { config: Config, events: *Events, io: std.Io } = null;

pub fn serve(io: std.Io, allocator: std.mem.Allocator, config: Config, events: *Events) !void {
    state = .{ .config = config, .events = events, .io = io };
    defer state = null;

    var server = try celer.Server.init(.{ .route_fn = route }, .{
        .port = config.port,
        .host = .localhost,
        .read_buffer_size = 16 * 1024,
        .write_buffer_size = 16 * 1024,
        .kernel_backlog = 128,
        .before_fn = null,
        .ws_handler = null,
    }, allocator);
    defer server.deinit();

    try server.start(io, allocator);
}

fn route(_: *celer.Server, allocator: std.mem.Allocator, request: *celer.Request) !void {
    const current = state orelse return error.HttpServerNotConfigured;
    if (request.req.head.method != .GET and request.req.head.method != .HEAD) {
        return request.respond(.{
            .body = "Method not allowed.\n",
            .options = .{ .status = .method_not_allowed, .keep_alive = false, .extra_headers = headers },
        });
    }

    const full_target = request.req.head.target;
    const target = full_target[0 .. std.mem.indexOfScalar(u8, full_target, '?') orelse full_target.len];
    if (std.mem.eql(u8, target, "/hmr/events"))
        return serveEvents(current.io, request, current.events);

    if (std.mem.startsWith(u8, target, "/hmr/"))
        return serveFile(allocator, current.io, request, current.config.hmr_directory, target["/hmr".len..]);

    if (std.mem.eql(u8, full_target, current.config.host_module_path)) {
        const location = try std.fmt.allocPrint(allocator, "{s}?knots-hmr", .{current.config.host_module_path});
        return request.respond(.{
            .body = "",
            .options = .{
                .status = .temporary_redirect,
                .keep_alive = request.req.head.keep_alive,
                .extra_headers = &.{.{ .name = "location", .value = location }},
            },
        });
    }

    return serveFile(allocator, current.io, request, current.config.web_directory, target);
}

fn serveEvents(io: std.Io, request: *celer.Request, events: *Events) !void {
    var buffer: [256]u8 = undefined;
    var body = try request.respondStreaming(&buffer, .{
        .respond_options = .{ .keep_alive = false, .extra_headers = &withContentType("text/event-stream") },
    });

    const keepalive: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(keepalive_seconds), .clock = .awake } };
    var revision: u64 = 0;
    while (true) {
        events.mutex.lockUncancelable(io);
        if (events.revision == revision) {
            events.condition.waitTimeout(io, &events.mutex, keepalive) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => {
                    events.mutex.unlock(io);
                    return err;
                },
            };
        }

        const next = events.revision;
        events.mutex.unlock(io);
        const sent = if (next != revision) sent: {
            revision = next;
            break :sent body.writer.print("event: change\ndata: {d}\n\n", .{revision});
        } else body.writer.writeAll(": keepalive\n\n");
        sent catch return;
        body.writer.flush() catch return;
        body.flush() catch return;
    }
}

fn serveFile(allocator: std.mem.Allocator, io: std.Io, request: *celer.Request, directory: []const u8, target: []const u8) !void {
    if (!safeTarget(target)) {
        return request.respond(.{
            .body = "Bad request.\n",
            .options = .{ .status = .bad_request, .extra_headers = headers },
        });
    }

    const relative = if (target.len == 1) "index.html" else target[1..];
    const path = try std.fs.path.join(allocator, &.{ directory, relative });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(file_bytes_max)) catch |err| {
        if (err == error.FileNotFound) {
            return request.respond(.{
                .body = "Not found.\n",
                .options = .{ .status = .not_found, .extra_headers = headers },
            });
        }

        return request.respond(.{
            .body = "Read failed.\n",
            .options = .{ .status = .internal_server_error, .extra_headers = headers },
        });
    };

    return request.respond(.{
        .body = bytes,
        .options = .{ .extra_headers = &withContentType(contentType(relative)) },
    });
}

fn safeTarget(target: []const u8) bool {
    if (target.len == 0 or target[0] != '/')
        return false;

    if (std.mem.startsWith(u8, target, "//"))
        return false;

    if (std.mem.indexOf(u8, target, "..") != null)
        return false;

    return std.mem.indexOfAny(u8, target, "\\:") == null;
}

fn withContentType(value: []const u8) [headers.len + 1]std.http.Header {
    return headers[0..headers.len].* ++ [_]std.http.Header{.{ .name = "content-type", .value = value }};
}

fn contentType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.mem.eql(u8, extension, ".html"))
        return "text/html; charset=utf-8";

    if (std.mem.eql(u8, extension, ".js"))
        return "text/javascript; charset=utf-8";

    if (std.mem.eql(u8, extension, ".wasm"))
        return "application/wasm";

    if (std.mem.eql(u8, extension, ".json"))
        return "application/json";

    return "application/octet-stream";
}
