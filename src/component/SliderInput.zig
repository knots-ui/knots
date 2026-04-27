const UI = @import("ui").UI;
const Style = @import("ui").Style;
const Element = @import("layout").Element;
const App = @import("knots").App;
const Theme = @import("ui").Theme;
const Color = @import("ui").Color;
const Decoration = UI.Decoration;
const std = @import("std");

value: *f32,
min: f32 = 0,
max: f32 = 1,
width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .fixed(4),
track_color: [4]f32 = Color.hex("#4d4d4d").value,
fill_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
corner_radius: f32 = 2,
onChange: ?*const fn (*App) anyerror!void = null,
key: UI.Key,

const SliderInput = @This();

pub fn open(self: *const SliderInput, app: *App) !Element.Id {
    const ui = &app.ui;
    const id = self.key.hash();

    const slider_state = try ui.state.getOrCreate(.slider, ui.allocator, id);

    if (ui.pressing(id) and ui.input.mouse_down) {
        const bounds = slider_state.bounds;
        if (bounds.w > 0) {
            const mx: f32 = @floatCast(ui.input.mouse_pos[0]);
            const t = std.math.clamp((mx - bounds.x) / bounds.w, 0, 1);
            const new_value = self.min + t * (self.max - self.min);
            if (new_value != self.value.*) {
                self.value.* = new_value;
                if (self.onChange) |cb| try cb(app);
            }
        }
    }

    const range = self.max - self.min;
    const progress: f32 = if (range > 0) std.math.clamp((self.value.* - self.min) / range, 0, 1) else 0;

    return try ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
        .interactive = true,
    }, .{ .slider = .{
        .progress = progress,
        .track_color = self.track_color,
        .fill_color = self.fill_color,
        .corner_radius = self.corner_radius,
    } });
}

pub fn close(_: *const SliderInput, app: *App) !void {
    app.ui.close();
}
