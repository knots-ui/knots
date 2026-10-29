//! Serves the installed web directory, and reloads its pages after each build:
//! every HTML page gets a script that listens to `/knots-dev/events`.

const std = @import("std");
const celer = @import("celer");

const file_bytes_max = 256 * 1024 * 1024;
const keepalive_seconds = 15;

const events_path = "/knots-dev/events";
const reload_script = "<script>new EventSource(\"" ++ events_path ++ "\").addEventListener(\"reload\", () => location.reload());</script>\n";

// Cross-origin isolation is necessary for shared-memory threads.
const headers: []const std.http.Header = &.{
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "cross-origin-opener-policy", .value = "same-origin" },
    .{ .name = "cross-origin-embedder-policy", .value = "require-corp" },
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    port: u16,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    revision: u64 = 0,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, directory: []const u8, port: u16) !*Server {
        const server = try gpa.create(Server);
        server.* = .{ .gpa = gpa, .io = io, .directory = directory, .port = port };
        return server;
    }

    pub fn reload(server: *Server) void {
        server.mutex.lockUncancelable(server.io);
        defer server.mutex.unlock(server.io);
        server.revision +%= 1;
        server.condition.broadcast(server.io);
    }

    pub fn run(server: *Server) void {
        serve(server) catch |err| switch (err) {
            error.Canceled => {},
            else => std.log.scoped(.knots_dev).err("the web server stopped: {t}", .{err}),
        };
    }
};

// celer routes get no context argument, so the server is global.
var current: ?*Server = null;

fn serve(server: *Server) !void {
    current = server;
    defer current = null;
    var http = try celer.Server.init(.{ .route_fn = route }, .{
        .port = server.port,
        .host = .localhost,
        .read_buffer_size = 16 * 1024,
        .write_buffer_size = 16 * 1024,
        .kernel_backlog = 128,
        .before_fn = null,
        .ws_handler = null,
    }, server.gpa);
    defer http.deinit();
    try http.start(server.io, server.gpa);
}

fn route(_: *celer.Server, allocator: std.mem.Allocator, request: *celer.Request) !void {
    const server = current orelse return error.ServerNotRunning;
    if (request.req.head.method != .GET and request.req.head.method != .HEAD) return request.respond(.{
        .body = "Method not allowed.\n",
        .options = .{ .status = .method_not_allowed, .keep_alive = false, .extra_headers = headers },
    });

    const full_target = request.req.head.target;
    const target = full_target[0 .. std.mem.indexOfScalar(u8, full_target, '?') orelse full_target.len];
    if (std.mem.eql(u8, target, events_path)) return serveEvents(server, request);
    return serveFile(server, allocator, request, target);
}

fn serveEvents(server: *Server, request: *celer.Request) !void {
    const io = server.io;
    var buffer: [256]u8 = undefined;
    var body = try request.respondStreaming(&buffer, .{
        .respond_options = .{ .keep_alive = false, .extra_headers = &withContentType("text/event-stream") },
    });

    const keepalive: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(keepalive_seconds), .clock = .awake } };
    server.mutex.lockUncancelable(io);
    var revision = server.revision;
    server.mutex.unlock(io);
    while (true) {
        server.mutex.lockUncancelable(io);
        if (server.revision == revision) {
            server.condition.waitTimeout(io, &server.mutex, keepalive) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => {
                    server.mutex.unlock(io);
                    return err;
                },
            };
        }
        const next = server.revision;
        server.mutex.unlock(io);
        const sent = if (next != revision) sent: {
            revision = next;
            break :sent body.writer.writeAll("event: reload\ndata:\n\n");
        } else body.writer.writeAll(": keepalive\n\n");
        sent catch return;
        body.writer.flush() catch return;
        body.flush() catch return;
    }
}

fn serveFile(server: *Server, allocator: std.mem.Allocator, request: *celer.Request, target: []const u8) !void {
    if (!safeTarget(target)) return request.respond(.{
        .body = "Bad request.\n",
        .options = .{ .status = .bad_request, .extra_headers = headers },
    });

    const relative = if (target.len == 1) "index.html" else target[1..];
    const path = try std.fs.path.join(allocator, &.{ server.directory, relative });
    const bytes = std.Io.Dir.cwd().readFileAlloc(server.io, path, allocator, .limited(file_bytes_max)) catch |err| return request.respond(.{
        .body = if (err == error.FileNotFound) "Not found.\n" else "Read failed.\n",
        .options = .{ .status = if (err == error.FileNotFound) .not_found else .internal_server_error, .extra_headers = headers },
    });

    const html = std.mem.eql(u8, std.fs.path.extension(relative), ".html");
    return request.respond(.{
        .body = if (html) try std.mem.concat(allocator, u8, &.{ bytes, reload_script }) else bytes,
        .options = .{ .extra_headers = &withContentType(contentType(relative)) },
    });
}

fn safeTarget(target: []const u8) bool {
    if (target.len == 0 or target[0] != '/') return false;
    if (std.mem.startsWith(u8, target, "//")) return false;
    if (std.mem.indexOf(u8, target, "..") != null) return false;
    return std.mem.indexOfAny(u8, target, "\\:") == null;
}

fn withContentType(value: []const u8) [headers.len + 1]std.http.Header {
    return headers[0..headers.len].* ++ [_]std.http.Header{.{ .name = "content-type", .value = value }};
}

fn contentType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.mem.eql(u8, extension, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, extension, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.eql(u8, extension, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, extension, ".json")) return "application/json";
    if (std.mem.eql(u8, extension, ".css")) return "text/css; charset=utf-8";
    return "application/octet-stream";
}
