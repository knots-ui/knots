const std = @import("std");

const response_read_buffer_bytes: u32 = 4 * 1024;
const event_line_bytes_max: u32 = 256;
const reconnect_delay_ms: u64 = 500;

comptime {
    std.debug.assert(response_read_buffer_bytes > 0);
    std.debug.assert(event_line_bytes_max > 0);
    std.debug.assert(reconnect_delay_ms > 0);
}

pub const Wake = struct {
    context: *anyopaque,
    notify: *const fn (*anyopaque) void,
};

pub fn get(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_url: []const u8,
    path: []const u8,
    bytes_max: u32,
) ![]u8 {
    std.debug.assert(base_url.len > 0);
    std.debug.assert(path.len > 0);
    std.debug.assert(path[0] == '/');
    std.debug.assert(bytes_max > 0);

    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, path });
    defer allocator.free(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var request = try client.request(.GET, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    });
    defer request.deinit();
    try request.sendBodiless();

    var response = try request.receiveHead(&.{});
    if (response.head.status != .ok) return error.HttpRequestFailed;
    const content_length = response.head.content_length orelse return error.HttpContentLengthRequired;
    if (content_length > @as(u64, bytes_max)) return error.HttpResponseTooLarge;

    const bytes = try allocator.alloc(u8, @intCast(content_length));
    errdefer allocator.free(bytes);
    var transfer_buffer: [response_read_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    try reader.readSliceAll(bytes);
    std.debug.assert(@as(u64, @intCast(bytes.len)) == content_length);
    return bytes;
}

pub fn watch(
    io: std.Io,
    allocator: std.mem.Allocator,
    base_url: []const u8,
    dirty: *std.atomic.Value(bool),
    wake: Wake,
) std.Io.Cancelable!void {
    std.debug.assert(base_url.len > 0);
    std.debug.assert(@intFromPtr(wake.context) > 0);
    std.debug.assert(@intFromPtr(wake.notify) > 0);

    const url = std.fmt.allocPrint(allocator, "{s}/hmr/events", .{base_url}) catch |err| {
        std.log.err("event=hmr_event_url_failed error={s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    while (true) {
        try std.Io.checkCancel(io);
        watchConnection(io, &client, url, dirty, wake) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.warn("event=hmr_event_stream_failed error={s} action=reconnect", .{@errorName(err)});
        };
        try std.Io.sleep(io, .fromMilliseconds(reconnect_delay_ms), .awake);
    }
}

fn watchConnection(
    io: std.Io,
    client: *std.http.Client,
    url: []const u8,
    dirty: *std.atomic.Value(bool),
    wake: Wake,
) !void {
    const uri = try std.Uri.parse(url);
    const headers: []const std.http.Header = &.{.{ .name = "accept", .value = "text/event-stream" }};
    var request = try client.request(.GET, uri, .{ .keep_alive = true, .redirect_behavior = .unhandled, .extra_headers = headers });
    defer request.deinit();
    try request.sendBodiless();

    var response = try request.receiveHead(&.{});
    if (response.head.status != .ok) return error.HttpRequestFailed;
    var transfer_buffer: [response_read_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var line: [event_line_bytes_max]u8 = undefined;
    var line_length: u32 = 0;
    var changed_event = false;

    while (true) {
        try std.Io.checkCancel(io);
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.HmrEventStreamClosed,
            // bodyErr only covers HTTP framing; transport errors, including
            // error.Canceled, live on the connection and must reach watch.
            error.ReadFailed => {
                if (response.bodyErr()) |body_err| return body_err;
                if (request.connection) |connection| {
                    if (connection.stream_reader.err) |stream_err| return stream_err;
                }
                return error.HmrEventStreamReadFailed;
            },
        };
        if (byte == '\n') {
            var line_bytes = line[0..@intCast(line_length)];
            if (std.mem.endsWith(u8, line_bytes, "\r")) line_bytes = line_bytes[0 .. line_bytes.len - 1];
            if (line_bytes.len == 0) {
                if (changed_event) {
                    dirty.store(true, .release);
                    wake.notify(wake.context);
                    changed_event = false;
                }
            } else if (std.mem.eql(u8, line_bytes, "event: change")) {
                changed_event = true;
            }
            line_length = 0;
            continue;
        }

        if (line_length == event_line_bytes_max) return error.HmrEventLineTooLong;
        line[@intCast(line_length)] = byte;
        line_length += 1;
    }
}
