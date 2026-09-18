const std = @import("std");
const playground = @import("playground");

pub fn main(init: std.process.Init) !void {
    var app = try playground.init(init.io, init.gpa, init.environ_map);
    defer app.deinit();
    try app.start();
}
