const std = @import("std");

const App = @import("knots").App;
const UI = @import("ui").UI;
const Style = @import("ui").Style;
const Element = @import("layout").Element;
const Decoration = UI.Decoration;

pub const DrawCmd = Decoration.DrawCmd;

width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .grow(),
style: Style = .{},
interactive: bool = false,
onDraw: *const fn (*App, *Painter) anyerror!void,
cmds: *std.ArrayList(DrawCmd),
key: UI.Key,

const Canvas = @This();

pub const Painter = struct {
    cmds: *std.ArrayList(DrawCmd),
    allocator: std.mem.Allocator,

    pub fn fillRect(self: *Painter, r: DrawCmd.FillRect) !void {
        try self.cmds.append(self.allocator, .{ .fill_rect = r });
    }

    pub fn fillRectGradient(self: *Painter, r: DrawCmd.FillRectGradient) !void {
        try self.cmds.append(self.allocator, .{ .fill_rect_gradient = r });
    }

    pub fn strokeRect(self: *Painter, r: DrawCmd.StrokeRect) !void {
        try self.cmds.append(self.allocator, .{ .stroke_rect = r });
    }

    pub fn fillCircle(self: *Painter, c: DrawCmd.FillCircle) !void {
        try self.cmds.append(self.allocator, .{ .fill_circle = c });
    }

    pub fn strokeCircle(self: *Painter, c: DrawCmd.StrokeCircle) !void {
        try self.cmds.append(self.allocator, .{ .stroke_circle = c });
    }

    pub fn line(self: *Painter, l: DrawCmd.Line) !void {
        try self.cmds.append(self.allocator, .{ .line = l });
    }

    pub fn fillTriangle(self: *Painter, t: DrawCmd.FillTriangle) !void {
        try self.cmds.append(self.allocator, .{ .fill_triangle = t });
    }

    pub fn fillConvexPolygon(self: *Painter, p: DrawCmd.FillConvexPolygon) !void {
        try self.cmds.append(self.allocator, .{ .fill_convex_polygon = p });
    }
};

pub fn open(self: *const Canvas, app: *App) !Element.Id {
    const decoration: Decoration = if (self.style.hasDecoration())
        .{ .rect = self.style.toRect() }
    else
        .none;
    return try app.ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
        .overflow = .hidden,
        .interactive = self.interactive,
    }, decoration);
}

pub fn close(self: *const Canvas, app: *App) !void {
    const ui = &app.ui;

    self.cmds.clearRetainingCapacity();
    var painter = Painter{ .cmds = self.cmds, .allocator = ui.allocator };
    try self.onDraw(app, &painter);

    ui.setDecoration(ui.currentSlot(), .{ .canvas = .{ .cmds = self.cmds.items } });

    ui.close();
}
