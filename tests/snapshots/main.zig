const std = @import("std");
const knots = @import("knots");
const Runner = @import("Runner.zig");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    _ = args.next();
    const backend = args.next() orelse return error.MissingBackend;
    if (!std.mem.eql(u8, backend, "vulkan") and !std.mem.eql(u8, backend, "webgpu")) return error.InvalidBackend;
    const update = if (args.next()) |arg| blk: {
        if (!std.mem.eql(u8, arg, "--update")) return error.InvalidArgument;
        break :blk true;
    } else false;
    if (args.next() != null) return error.TooManyArguments;

    var runner = try Runner.init(init.io, init.gpa, backend, update);
    defer runner.deinit();
    try runner.start();
}
