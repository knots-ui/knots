//! Line icons for window buttons, drawn in the current element's foreground.
const std = @import("std");

const ui_mod = @import("../root.zig");
const Frame = ui_mod.Frame;
const Key = ui_mod.Key;
const DrawCmd = ui_mod.Decoration.DrawCmd;

pub const Icon = enum {
    minimize,
    maximize,
    restore,
    close,
};

const thickness: f32 = 1.75;

pub fn open(frame: *Frame, key: Key, icon: Icon, size: f32) !void {
    const ui = frame.ui();
    const color = ui.contents.items[ui.currentSlot()].foreground;
    const cmds = try frame.arena().alloc(DrawCmd, switch (icon) {
        .minimize => 1,
        .close => 2,
        .maximize => 4,
        .restore => 8,
    });
    switch (icon) {
        .minimize => cmds[0] = line(size, .{ 0.22, 0.5 }, .{ 0.78, 0.5 }, color),
        .close => {
            cmds[0] = line(size, .{ 0.25, 0.25 }, .{ 0.75, 0.75 }, color);
            cmds[1] = line(size, .{ 0.75, 0.25 }, .{ 0.25, 0.75 }, color);
        },
        .maximize => square(cmds[0..4], size, 0.22, 0.22, 0.56, color),
        .restore => {
            square(cmds[0..4], size, 0.18, 0.34, 0.48, color);
            square(cmds[4..8], size, 0.34, 0.18, 0.48, color);
        },
    }
    _ = try ui.open(key, .{ .width = .fixed(size), .height = .fixed(size) }, .{ .canvas = .{ .cmds = cmds } });
    ui.close();
}

fn line(size: f32, from: [2]f32, to: [2]f32, color: [4]f32) DrawCmd {
    return .{ .line = .{
        .from = .{ size * from[0], size * from[1] },
        .to = .{ size * to[0], size * to[1] },
        .color = color,
        .thickness = thickness,
    } };
}

fn square(cmds: []DrawCmd, size: f32, x: f32, y: f32, extent: f32, color: [4]f32) void {
    std.debug.assert(cmds.len == 4);
    const right = x + extent;
    const bottom = y + extent;
    cmds[0] = line(size, .{ x, y }, .{ right, y }, color);
    cmds[1] = line(size, .{ right, y }, .{ right, bottom }, color);
    cmds[2] = line(size, .{ right, bottom }, .{ x, bottom }, color);
    cmds[3] = line(size, .{ x, bottom }, .{ x, y }, color);
}
