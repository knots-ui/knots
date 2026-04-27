const std = @import("std");

const App = @import("knots").App;
const UI = @import("ui").UI;

samples: [60]f32 = [_]f32{0} ** 60,
index: usize = 0,
fps_label: []const u8 = "",
fps_buf: []u8,

const Perf = @This();

pub fn open(self: *const Perf, app: *App) !u32 {
    var deco = try app.ui.textDecoration(self.fps_label, 8, null);
    deco.text.color = .{ 1.0, 0.0, 0.0, 1.0 };
    return try app.ui.openRoot(.src(@src()), 0, 0, .{ .z_index = 255 }, deco);
}

pub fn close(_: *const Perf, app: *App) !void {
    app.ui.close();
}

pub fn updateFps(self: *Perf, duration: std.Io.Duration) !void {
    const delta_t: f32 = @as(f32, @floatFromInt(duration.toNanoseconds())) / std.time.ns_per_s;
    self.samples[self.index] = if (delta_t > 0) 1.0 / delta_t else 0;
    self.index = (self.index + 1) % self.samples.len;
    self.fps_label = try std.fmt.bufPrint(self.fps_buf, "{d:.1}FPS", .{self.fps()});
}

pub fn fps(self: *const Perf) f32 {
    const vec: @Vector(60, f32) = self.samples;
    const sum = @reduce(.Add, vec);
    return sum / @as(f32, @floatFromInt(60));
}
