const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const tracy = @import("tracy.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Spacer = ui.component.Spacer;
const Canvas = ui.component.Canvas;
const For = knots.control.For;

const grid_cols = 80;
const grid_rows = 600;
const sidebar_items = 5000;
const cell_size = 14.0;
const elements = grid_rows * grid_cols + sidebar_items;

const title = std.fmt.comptimePrint(
    "Knots Benchmark  |  {d} elements  |  grid {d}x{d}  |  sidebar {d}",
    .{ elements, grid_cols, grid_rows, sidebar_items },
);

const Context = struct {
    app: knots.App,
    dev_tools: knots.debug.DevTools,
};

pub fn main(init: std.process.Init) !void {
    var app = try knots.App.init(init.io, init.gpa, .{
        .window = .{
            .width = 1600,
            .height = 1000,
            .title = "Knots Benchmark",
        },
        .renderer = .{ .present_mode = .fifo },
    });
    errdefer app.deinit();

    var ctx = Context{
        .app = app,
        .dev_tools = try .init(init.gpa, app.main_viewport.renderer.cfg.present_mode),
    };
    defer {
        ctx.dev_tools.deinit(init.gpa);
        ctx.app.deinit();
    }

    try ctx.app.start(frameCb);
}

fn frameCb(view: *knots.View, frame: *ui.Frame) !void {
    const zone = tracy.zoneBegin("frameCb", @src());
    defer tracy.zoneEnd(zone);

    const self: *Context = @fieldParentPtr("app", view.app);
    const size = frame.input().logical_extent;
    const w: f32 = @floatFromInt(size.width);
    const h: f32 = @floatFromInt(size.height);

    try frame.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .fixed(w), .height = .fixed(h), .padding = .init(8, 8, 8, 8), .direction = .column, .gap = 8 },
        },
        .{
            renderHeader,
            renderBody,
            renderCanvasStrip,
        },
    });

    try self.dev_tools.render(frame, .{
        .frame_delta_ns = frame.input().delta_ns,
        .window_width = @floatFromInt(frame.input().logical_extent.width),
        .window_height = @floatFromInt(frame.input().logical_extent.height),
    });
    tracy.frameMark();
}

fn renderHeader(app: *ui.Frame) !void {
    const zone = tracy.zoneBegin("renderHeader", @src());
    defer tracy.zoneEnd(zone);

    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .height = .fixed(48), .padding = .init(8, 16, 8, 16), .direction = .row, .@"align" = .center, .justify = .space_between, .gap = 16, .background = .bg, .border_width = .all(1), .border_color = .toned, .radius = .sm },
        },
        .{Text{ .key = .src(@src()), .content = title }},
    });
}

fn renderBody(app: *ui.Frame) !void {
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .height = .grow(), .direction = .row, .gap = 8 },
        },
        .{
            renderSidebar,
            renderGrid,
        },
    });
}

fn renderSidebar(app: *ui.Frame) !void {
    const zone = tracy.zoneBegin("renderSidebarItems", @src());
    defer tracy.zoneEnd(zone);
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .fixed(260), .height = .grow(), .padding = .init(8, 8, 8, 8), .direction = .column, .gap = 4, .overflow = .scroll_y, .background = .bg, .border_width = .all(1), .border_color = .toned, .radius = .sm },
        },
        .{renderSidebarItems},
    });
}

fn renderSidebarItems(app: *ui.Frame) !void {
    const arena = app.arena();
    var i: usize = 0;
    while (i < sidebar_items) : (i += 1) {
        const label = try std.fmt.allocPrint(arena, "row {d}", .{i});
        try app.e(.{
            Button{
                .key = ui.Key.src(@src()).indexed(i),
                .label = label,
                .style = &.{ .width = .grow(), .height = .fixed(22), .padding = .init(2, 8, 2, 8), .justify = .start, .background = if (i & 1 == 0) .muted else .toned, .font_size = .xs },
            },
        });
    }
}

fn renderGrid(app: *ui.Frame) !void {
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .height = .grow(), .padding = .init(8, 8, 8, 8), .direction = .column, .gap = 2, .overflow = .scroll_y, .background = .bg, .border_width = .all(1), .border_color = .toned, .radius = .sm },
        },
        .{renderGridRows},
    });
}

fn renderGridRows(app: *ui.Frame) !void {
    const zone = tracy.zoneBegin("renderGridRows", @src());
    defer tracy.zoneEnd(zone);

    var r: usize = 0;
    while (r < grid_rows) : (r += 1) {
        try renderGridRow(app, r);
    }
}

fn renderGridRow(app: *ui.Frame, r: usize) !void {
    const row_key = ui.Key.src(@src()).indexed(r);

    try app.e(.{
        Rect{
            .key = row_key,
            .style = &.{ .width = .grow(), .height = .fixed(cell_size), .direction = .row, .gap = 2 },
        },
        .{GridCells{ .row = r }},
    });
}

const GridCells = struct {
    row: usize,

    pub fn render(self: *const GridCells, app: *ui.Frame) anyerror!void {
        const zone = tracy.zoneBegin("GridCells.render", @src());
        defer tracy.zoneEnd(zone);

        var c: usize = 0;
        while (c < grid_cols) : (c += 1) {
            const idx = self.row * grid_cols + c;
            const k = ui.Key.src(@src()).indexed(idx);
            const hue: f32 = @floatFromInt((idx * 13) % 360);
            const color = hsvToRgb(hue / 360.0, 0.55, 0.85);
            const label = try std.fmt.allocPrint(app.arena(), "{d}", .{(idx % 100)});
            try app.e(.{
                Button{
                    .key = k,
                    .label = label,
                    .style = &.{ .width = .fixed(cell_size), .height = .fixed(cell_size), .background = .{ .color = .{ .value = color } }, .font_size = .{ .px = 9 } },
                },
            });
        }
    }
};

fn renderCanvasStrip(app: *ui.Frame) !void {
    const zone = tracy.zoneBegin("drawCanvas", @src());
    defer tracy.zoneEnd(zone);

    var commands: std.ArrayList(Canvas.DrawCmd) = .empty;
    var painter = Canvas.Painter{
        .cmds = &commands,
        .allocator = app.arena(),
    };
    try drawCanvas(app, &painter);

    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .height = .fixed(160), .background = .bg, .border_width = .all(1), .border_color = .toned, .radius = .sm, .overflow = .scroll_x },
        },
        .{Canvas{
            .key = .src(@src()),
            .commands = commands.items,
            .style = &.{ .width = .grow(), .height = .grow() },
        }},
    });
}

fn drawCanvas(app: *ui.Frame, painter: *Canvas.Painter) !void {
    const zone = tracy.zoneBegin("drawCanvas", @src());
    defer tracy.zoneEnd(zone);

    const t = @as(f32, @floatFromInt(@mod(app.input().now_ms, 4000))) / 4000.0;
    const bands: usize = 256;
    const bw: f32 = 2500.0 / @as(f32, @floatFromInt(bands));
    var i: usize = 0;
    while (i < bands) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const phase = @mod(fi / @as(f32, @floatFromInt(bands)) + t, 1.0);
        try painter.fillRectGradient(.{
            .x = fi * bw,
            .y = 0,
            .w = bw,
            .h = 160,
            .colors = .{
                hsvToRgb(phase, 0.7, 0.9),
                hsvToRgb(@mod(phase + 0.05, 1.0), 0.7, 0.9),
                hsvToRgb(@mod(phase + 0.1, 1.0), 0.5, 0.6),
                hsvToRgb(@mod(phase + 0.05, 1.0), 0.5, 0.6),
            },
        });
    }

    app.requestRedraw();
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
