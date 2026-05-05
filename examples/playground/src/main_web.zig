const std = @import("std");
const playground = @import("playground");

pub const knots_theme = @import("theme.zon");

pub const std_options: std.Options = .{
    .logFn = webLog,
};

fn webLog(comptime level: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrintSentinel(std.heap.c_allocator, format, args, 0x00) catch return;
    defer std.heap.c_allocator.free(msg);
    switch (level) {
        inline .debug => std.os.emscripten.emscripten_log(std.os.emscripten.LOG.DEBUG, msg.ptr),
        inline .info => std.os.emscripten.emscripten_log(std.os.emscripten.LOG.INFO, msg.ptr),
        inline .warn => std.os.emscripten.emscripten_log(std.os.emscripten.LOG.WARN, msg.ptr),
        inline .err => std.os.emscripten.emscripten_log(std.os.emscripten.LOG.ERROR, msg.ptr),
    }
}

export fn main(_: c_int, _: [*][*:0]u8) c_int {
    const allocator = std.heap.c_allocator;

    var threaded_io: std.Io.Threaded = .init_single_threaded;
    defer threaded_io.deinit();

    const io = threaded_io.io();

    const app = allocator.create(playground) catch return -1;
    app.* = playground.init(io, allocator) catch return -1;
    app.start() catch return -1;
    return 0;
}
