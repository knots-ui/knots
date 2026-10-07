//! Usage: knots-dev-host <Builder.Options flags>

const std = @import("std");
const Builder = @import("hmr_builder");
const Host = @import("Host.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());

    var options: Builder.Options = .{};
    if ((try options.parse(init.arena.allocator(), arguments[1..])).len > 0)
        return error.UnknownFlag;

    var host: Host = undefined;
    try host.init(gpa, io);
    defer host.deinit();

    const builder = try Builder.init(
        io,
        gpa,
        init.environ_map,
        options,
        .{
            .context = &host,
            .publish = publish,
        },
    );
    defer builder.deinit();
    try builder.start();

    var stop: std.atomic.Value(bool) = .init(false);
    var tasks: std.Io.Group = .init;
    defer {
        stop.store(true, .release);
        tasks.cancel(io);
    }

    try tasks.concurrent(io, Builder.watch, .{ builder, &stop });
    try host.run();
}

fn publish(context: *anyopaque, result: Builder.Result) void {
    const host: *Host = @ptrCast(@alignCast(context));
    switch (result) {
        .app => |bytes| host.publishApp(bytes),
        .failed => |diagnostics| host.publishFailure(diagnostics),
    }
}
