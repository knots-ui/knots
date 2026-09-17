const std = @import("std");

const Element = @import("layout").Element;
const Decoration = @import("../root.zig").Decoration;
const Style = @import("../root.zig").Style;
const Key = @import("../root.zig").Key;
const Frame = @import("../root.zig").Frame;

pub const DrawCmd = Decoration.DrawCmd;

width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .grow(),
style: Style = .{},
interactive: bool = false,
commands: []const DrawCmd = &.{},
key: Key,

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
        const points = try self.allocator.dupe([2]f32, p.points);
        try self.cmds.append(self.allocator, .{ .fill_convex_polygon = .{
            .points = points,
            .color = p.color,
        } });
    }
};

pub fn open(self: *const Canvas, frame: *Frame) !Element.Id {
    const rect = self.style.toRect(&frame.ui().theme);
    const needs_clip_shape = !rect.corner_radius.isZero() or !rect.border_width.isZero();
    const decoration: Decoration = if (self.style.hasDecoration() or needs_clip_shape)
        .{ .rect = rect }
    else
        .none;
    return try frame.ui().open(self.key, .{
        .width = self.width,
        .height = self.height,
        .overflow = .hidden,
        .interactive = self.interactive,
    }, decoration);
}

pub fn close(self: *const Canvas, frame: *Frame) !void {
    const ui = frame.ui();
    const commands = try frame.arena().dupe(DrawCmd, self.commands);
    try copyBorrowedCommandData(frame.arena(), commands);
    ui.setDecoration(ui.currentSlot(), .{ .canvas = .{ .cmds = commands } });

    ui.close();
}

fn copyBorrowedCommandData(
    allocator: std.mem.Allocator,
    commands: []DrawCmd,
) !void {
    for (commands) |*command| {
        switch (command.*) {
            .fill_convex_polygon => |polygon| {
                command.fill_convex_polygon.points =
                    try allocator.dupe([2]f32, polygon.points);
            },
            else => {},
        }
    }
}

test "canvas copies polygon point slices into frame storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var points = [_][2]f32{ .{ 1, 2 }, .{ 3, 4 }, .{ 5, 6 } };
    const source = [_]DrawCmd{.{ .fill_convex_polygon = .{
        .points = &points,
        .color = .{ 1, 1, 1, 1 },
    } }};
    const commands = try arena.allocator().dupe(DrawCmd, &source);
    try copyBorrowedCommandData(arena.allocator(), commands);

    points[0] = .{ 9, 9 };
    try std.testing.expectEqual(
        [2]f32{ 1, 2 },
        commands[0].fill_convex_polygon.points[0],
    );
}
