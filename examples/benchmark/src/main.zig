const std = @import("std");
const knots = @import("knots");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;
const Canvas = knots.component.Canvas;
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
    allocator: std.mem.Allocator,
    app: knots.App,
    canvas_cmds: std.ArrayList(Canvas.DrawCmd),
    renderer_settings: knots.debug.RendererSettings,
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
        .allocator = init.gpa,
        .app = app,
        .canvas_cmds = .empty,
        .renderer_settings = try .init(init.gpa, app.renderer.cfg.gpu_backend, app.renderer.cfg.present_mode),
    };
    defer {
        ctx.renderer_settings.deinit(init.gpa);
        ctx.canvas_cmds.deinit(init.gpa);
        ctx.app.deinit();
    }

    try ctx.app.start(frameCb);
}

fn frameCb(app: *knots.App) !void {
    const size = app.window.getSize();
    const w: f32 = @floatFromInt(size.width);
    const h: f32 = @floatFromInt(size.height);

    try app.e(.{
        Rect{
            .key = .src(@src()),
            .width = .fixed(w),
            .height = .fixed(h),
            .padding = .init(8, 8, 8, 8),
            .dir = .column,
            .gap = 8,
        },
        .{
            renderHeader,
            renderBody,
            renderCanvasStrip,
        },
    });

    try app.signal(.redraw);
}

fn renderHeader(app: *knots.App) !void {
    const self: *Context = @fieldParentPtr("app", app);

    try app.e(.{
        Rect{
            .key = .src(@src()),
            .width = .grow(),
            .height = .fixed(48),
            .padding = .init(8, 16, 8, 16),
            .dir = .row,
            .@"align" = .center,
            .justify = .space_between,
            .gap = 16,
            .style = .{ .color = .bg, .border_width = 1, .border_color = .toned, .corner_radius = .sm },
        },
        .{
            Text{
                .key = .src(@src()),
                .content = title,
                .size = 14,
            },
            Rect{
                .key = .src(@src()),
                .width = .fit(),
                .height = .fit(),
                .dir = .row,
                .@"align" = .center,
                .gap = 8,
            },
            .{self.renderer_settings},
        },
    });
}

fn renderBody(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .width = .grow(),
            .height = .grow(),
            .dir = .row,
            .gap = 8,
        },
        .{
            renderSidebar,
            renderGrid,
        },
    });
}

fn renderSidebar(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .width = .fixed(260),
            .height = .grow(),
            .padding = .init(8, 8, 8, 8),
            .dir = .column,
            .gap = 4,
            .overflow = .scroll_y,
            .style = .{ .color = .bg, .border_width = 1, .border_color = .toned, .corner_radius = .sm },
        },
        .{renderSidebarItems},
    });
}

fn renderSidebarItems(app: *knots.App) !void {
    const arena = app.arena();
    var i: usize = 0;
    while (i < sidebar_items) : (i += 1) {
        const label = try std.fmt.allocPrint(arena, "row {d}", .{i});
        try app.e(.{
            Button{
                .key = knots.ui.Key.src(@src()).indexed(i),
                .width = .grow(),
                .height = .fixed(22),
                .padding = .init(2, 8, 2, 8),
                .@"align" = .center,
                .justify = .start,
                .style = .{ .color = if (i & 1 == 0) .muted else .toned, .corner_radius = .sm },
                .hover_anim = .{},
                .text = .{ .content = label, .size = 11 },
            },
        });
    }
}

fn renderGrid(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .width = .grow(),
            .height = .grow(),
            .padding = .init(8, 8, 8, 8),
            .dir = .column,
            .gap = 2,
            .overflow = .scroll_y,
            .style = .{ .color = .bg, .border_width = 1, .border_color = .toned, .corner_radius = .sm },
        },
        .{renderGridRows},
    });
}

fn renderGridRows(app: *knots.App) !void {
    var r: usize = 0;
    while (r < grid_rows) : (r += 1) {
        try renderGridRow(app, r);
    }
}

fn renderGridRow(app: *knots.App, r: usize) !void {
    const row_key = knots.ui.Key.src(@src()).indexed(r);

    try app.e(.{
        Rect{
            .key = row_key,
            .width = .grow(),
            .height = .fixed(cell_size),
            .dir = .row,
            .gap = 2,
        },
        .{
            GridCells{ .row = r },
        },
    });
}

const GridCells = struct {
    row: usize,

    pub fn render(self: *const GridCells, app: *knots.App) anyerror!void {
        var c: usize = 0;
        while (c < grid_cols) : (c += 1) {
            const idx = self.row * grid_cols + c;
            const k = knots.ui.Key.src(@src()).indexed(idx);
            const hue: f32 = @floatFromInt((idx * 13) % 360);
            const color = hsvToRgb(hue / 360.0, 0.55, 0.85);
            const label = try std.fmt.allocPrint(app.arena(), "{d}", .{(idx % 100)});
            try app.e(.{
                Button{
                    .key = k,
                    .width = .fixed(cell_size),
                    .height = .fixed(cell_size),
                    .@"align" = .center,
                    .justify = .center,
                    .style = .{
                        .color = .{ .color = .{ .value = color } },
                        .corner_radius = .sm,
                    },
                    .hover_anim = .{ .brighten = 0.35 },
                    .text = .{ .content = label, .size = 9 },
                },
            });
        }
    }
};

fn renderCanvasStrip(app: *knots.App) !void {
    const self: *Context = @fieldParentPtr("app", app);
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .width = .grow(),
            .height = .fixed(160),
            .style = .{ .color = .bg, .border_width = 1, .border_color = .toned, .corner_radius = .sm },
            .overflow = .scroll_x,
        },
        .{Canvas{
            .key = .src(@src()),
            .width = .grow(),
            .height = .grow(),
            .cmds = &self.canvas_cmds,
            .onDraw = drawCanvas,
        }},
    });
}

fn drawCanvas(app: *knots.App, painter: *Canvas.Painter) !void {
    const t = @as(f32, @floatFromInt(@mod(app.timer.ms(), 4000))) / 4000.0;
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
