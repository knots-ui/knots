const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Canvas = ui.component.Canvas;
const SelectInput = ui.component.SelectInput;
const Spacer = ui.component.Spacer;

const Effect = enum { gradient, clock, bars, polygon };

const canvas_width = 720;
const canvas_height = 480;

pub fn render(desktop: *knots.App, app: *ui.Frame) !void {
    try ui_helpers.panel(desktop, app, "Canvas", body);
}

fn body(desktop: *knots.App, app: *ui.Frame) !void {
    const self = Self.of(desktop);

    const controls = Rect{ .width = .fixed(220), .key = .src(@src()) };
    _ = try controls.open(app);
    const selection = try app.interact(SelectInput(Effect){
        .key = .src(@src()),
        .initial_selected = self.demo_state.canvas_effect,
    });
    if (selection.selected) |selected| self.demo_state.canvas_effect = selected.index;
    try controls.close(app);

    try app.e(Spacer{ .height = .fixed(12), .key = .src(@src()) });

    var commands: std.ArrayList(Canvas.DrawCmd) = .empty;
    var painter = Canvas.Painter{
        .cmds = &commands,
        .allocator = app.arena(),
    };
    const effect: Effect = @fromBackingInt(@intCast(self.demo_state.canvas_effect));
    switch (effect) {
        .gradient => try drawGradient(app, &painter),
        .clock => try drawClock(app, &painter),
        .bars => try drawBars(&painter),
        .polygon => try drawPolygon(&painter),
    }
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .grow(),
            .key = .src(@src()),
            .style = .{ .color = .elevated, .corner_radius = .sm },
            .overflow = .scroll,
        },
        .{Canvas{
            .width = .fixed(canvas_width),
            .height = .fixed(canvas_height),
            .commands = commands.items,
            .key = .src(@src()),
        }},
    });
}

fn drawGradient(app: *ui.Frame, painter: *Canvas.Painter) !void {
    const w: f32 = canvas_width;
    const h: f32 = canvas_height;
    const t = @as(f32, @floatFromInt(@mod(app.input().now_ms, 10000))) / 10000.0;
    const n = 12;

    var i: usize = 0;
    while (i < n) : (i += 1) {
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const fi: f32 = @floatFromInt(i);
            const fj: f32 = @floatFromInt(j);
            const fn_: f32 = @floatFromInt(n);
            const cell_w = w / fn_;
            const cell_h = h / fn_;

            const hue_tl = @mod((fi / fn_) * 0.75 + (fj / fn_) * 0.57 + t, 1.0);
            const hue_tr = @mod((fi / fn_) * 0.75 + ((fj + 1) / fn_) * 0.57 + t, 1.0);
            const hue_br = @mod(((fi + 1) / fn_) * 0.75 + ((fj + 1) / fn_) * 0.57 + t, 1.0);
            const hue_bl = @mod(((fi + 1) / fn_) * 0.75 + (fj / fn_) * 0.57 + t, 1.0);

            try painter.fillRectGradient(.{
                .x = fj * cell_w,
                .y = fi * cell_h,
                .w = cell_w,
                .h = cell_h,
                .colors = .{
                    hsvToRgb(hue_tl, 0.7, 0.85),
                    hsvToRgb(hue_tr, 0.7, 0.85),
                    hsvToRgb(hue_br, 0.7, 0.85),
                    hsvToRgb(hue_bl, 0.7, 0.85),
                },
            });
        }
    }

    app.requestRedraw();
}

fn drawClock(app: *ui.Frame, painter: *Canvas.Painter) !void {
    const w: f32 = canvas_width;
    const h: f32 = canvas_height;
    const cx = w / 2;
    const cy = h / 2;
    const r = @min(w, h) / 2 - 20;

    try painter.fillCircle(.{ .cx = cx, .cy = cy, .radius = r, .color = .{ 0.12, 0.10, 0.09, 1.0 } });
    try painter.strokeCircle(.{ .cx = cx, .cy = cy, .radius = r, .color = .{ 0.83, 0.46, 0.18, 1.0 }, .thickness = 2 });

    var tick: usize = 0;
    while (tick < 12) : (tick += 1) {
        const angle = @as(f32, @floatFromInt(tick)) * std.math.pi * 2.0 / 12.0 - std.math.pi / 2.0;
        const inner = r - 10;
        const outer = r - 2;
        try painter.line(.{
            .from = .{ cx + std.math.cos(angle) * inner, cy + std.math.sin(angle) * inner },
            .to = .{ cx + std.math.cos(angle) * outer, cy + std.math.sin(angle) * outer },
            .color = .{ 0.83, 0.46, 0.18, 1.0 },
            .thickness = 2,
        });
    }

    const ms = app.input().now_ms;
    const seconds_f = @as(f32, @floatFromInt(@mod(ms, 60_000))) / 1000.0;
    const minutes_f = @as(f32, @floatFromInt(@mod(ms, 3_600_000))) / 60_000.0;
    const hours_f = @as(f32, @floatFromInt(@mod(ms, 43_200_000))) / 3_600_000.0;

    const sec_angle = seconds_f * std.math.pi * 2.0 / 60.0 - std.math.pi / 2.0;
    const min_angle = minutes_f * std.math.pi * 2.0 / 60.0 - std.math.pi / 2.0;
    const hour_angle = hours_f * std.math.pi * 2.0 / 12.0 - std.math.pi / 2.0;

    try painter.line(.{
        .from = .{ cx, cy },
        .to = .{ cx + std.math.cos(hour_angle) * (r * 0.5), cy + std.math.sin(hour_angle) * (r * 0.5) },
        .color = .{ 0.95, 0.95, 0.95, 1.0 },
        .thickness = 4,
    });
    try painter.line(.{
        .from = .{ cx, cy },
        .to = .{ cx + std.math.cos(min_angle) * (r * 0.7), cy + std.math.sin(min_angle) * (r * 0.7) },
        .color = .{ 0.85, 0.85, 0.85, 1.0 },
        .thickness = 3,
    });
    try painter.line(.{
        .from = .{ cx, cy },
        .to = .{ cx + std.math.cos(sec_angle) * (r * 0.85), cy + std.math.sin(sec_angle) * (r * 0.85) },
        .color = .{ 0.83, 0.46, 0.18, 1.0 },
        .thickness = 1.5,
    });

    try painter.fillCircle(.{ .cx = cx, .cy = cy, .radius = 4, .color = .{ 0.83, 0.46, 0.18, 1.0 } });

    app.requestRedraw();
}

fn drawBars(painter: *Canvas.Painter) !void {
    const values = [_]f32{ 0.42, 0.78, 0.31, 0.95, 0.66, 0.55, 0.82, 0.27, 0.71 };
    const padding: f32 = 30;
    const chart_w: f32 = 540;
    const chart_h: f32 = 280;
    const bar_gap: f32 = 8;
    const bar_w: f32 = (chart_w - bar_gap * (values.len - 1)) / values.len;

    try painter.strokeRect(.{
        .x = padding,
        .y = padding,
        .w = chart_w,
        .h = chart_h,
        .color = .{ 0.4, 0.4, 0.4, 1.0 },
        .thickness = 1,
    });

    for (values, 0..) |v, i| {
        const fi: f32 = @floatFromInt(i);
        const x = padding + fi * (bar_w + bar_gap);
        const bar_h = v * chart_h;
        const y = padding + chart_h - bar_h;

        try painter.fillRect(.{
            .x = x,
            .y = y,
            .w = bar_w,
            .h = bar_h,
            .color = .{ 0.83, 0.46, 0.18, 1.0 },
        });
    }
}

fn drawPolygon(painter: *Canvas.Painter) !void {
    const cx: f32 = 280;
    const cy: f32 = 180;
    const r: f32 = 100;
    const sides = 6;

    var pts: [sides][2]f32 = undefined;
    var k: usize = 0;
    while (k < sides) : (k += 1) {
        const angle = @as(f32, @floatFromInt(k)) * std.math.pi * 2.0 / @as(f32, @floatFromInt(sides));
        pts[k] = .{ cx + std.math.cos(angle) * r, cy + std.math.sin(angle) * r };
    }

    try painter.fillConvexPolygon(.{
        .points = &pts,
        .color = .{ 0.32, 0.55, 0.66, 1.0 },
    });

    try painter.fillTriangle(.{
        .points = .{
            .{ cx, cy - 60 },
            .{ cx - 50, cy + 30 },
            .{ cx + 50, cy + 30 },
        },
        .color = .{ 0.83, 0.46, 0.18, 1.0 },
    });
}

fn srgbToLinear(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn hsvToRgb(h: f32, s: f32, v: f32) [4]f32 {
    const h6 = h * 6.0;
    const i = @as(u32, @intFromFloat(@floor(h6))) % 6;
    const f = h6 - @floor(h6);
    const p = v * (1.0 - s);
    const q = v * (1.0 - s * f);
    const t = v * (1.0 - s * (1.0 - f));
    const srgb: [3]f32 = switch (i) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
    return .{ srgbToLinear(srgb[0]), srgbToLinear(srgb[1]), srgbToLinear(srgb[2]), 1.0 };
}
