const Frame = @import("../root.zig").Frame;

const Element = @import("layout").Element;
const ui_mod = @import("../root.zig");

const Key = ui_mod.Key;
const Style = ui_mod.Style;

pub const CloseReason = enum {
    escape,
    backdrop,
};

is_open: *bool,
key: Key,

close_on_escape: bool = true,
close_on_backdrop_press: bool = true,

/// The panel: hosts the children.
style: *const Style = &.{},
parts: Parts = .{},

pub const Parts = struct {
    /// Covers the viewport: `background`, `padding` (margin around the panel), `layer`.
    backdrop: *const Style = &.{},
};

pub const base = struct {
    pub const root: Style = .{
        .width = .{ .kind = .fit, .max = 640 },
        .direction = .column,
        .padding = .all(16),
        .overflow = .scroll_y,
        .background = .elevated,
        .foreground = .text,
        .radius = .md,
        .border_width = .all(1),
        .border_color = .toned,
    };
    pub const backdrop: Style = .{
        .direction = .layer,
        .@"align" = .center,
        .justify = .center,
        .padding = .all(24),
        .layer = .modal,
        .background = .{ .color = .{ .value = .{ 0, 0, 0, 0.45 } } },
    };
};

const Dialog = @This();

const PANEL_INDEX: usize = 2;

pub fn open(self: *const Dialog, frame: *Frame) !Element.Id {
    if (!self.is_open.*) return Element.INVALID_ID;

    const ui = frame.ui();
    const input = frame.input();
    const size = input.logical_extent;
    const viewport_w: f32 = @floatFromInt(size.width);
    const viewport_h: f32 = @floatFromInt(size.height);

    const backdrop = ui.resolveStyle(self.key.hash(), .{ .base = &base.backdrop, .user = self.parts.backdrop }, .{}, null);
    var root_config = backdrop.element(.{ .interactive = true });
    root_config.width = .fixed(viewport_w);
    root_config.height = .fixed(viewport_h);
    const root_id = try ui.openResolved(self.key, &backdrop, root_config, .{ 0, 0 });
    try ui.beginInputScope(root_id, .modal);

    const margin = backdrop.layout.padding;
    const panel_max_w = @max(0, viewport_w - margin.left() - margin.right());
    const panel_max_h = @max(0, viewport_h - margin.top() - margin.bottom());
    const panel = ui.resolveStyle(self.key.indexed(PANEL_INDEX).hash(), .{ .base = &base.root, .user = self.style }, .{}, null);
    var panel_config = panel.element(.{ .interactive = true });
    panel_config.width = clampAxisToMax(panel_config.width, panel_max_w);
    panel_config.height = clampAxisToMax(panel_config.height, panel_max_h);
    const panel_id = try ui.openResolved(self.key.indexed(PANEL_INDEX), &panel, panel_config, null);
    try ui.setAccessibility(panel_id, .{
        .role = .dialog,
        .state = .{ .expanded = true },
    });

    return root_id;
}

pub fn close(self: *const Dialog, frame: *Frame) !void {
    _ = try self.closeResponse(frame);
}

pub fn closeResponse(self: *const Dialog, frame: *Frame) !?CloseReason {
    const ui = frame.ui();
    const root_id = self.key.hash();
    if (ui.layout_ctx.slotForId(root_id) == null) return null;

    var response: ?CloseReason = null;
    if (ui.isActiveScope(root_id)) {
        if (self.close_on_backdrop_press and ui.leftPressed(root_id, .exact)) {
            response = self.requestClose(frame, .backdrop);
        } else if (self.close_on_escape and ui.input.containsKey(.escape)) {
            response = self.requestClose(frame, .escape);
            ui.input.consumeKeyboard();
        }
    }

    if (!self.is_open.*) ui.cancelInputScope(root_id);

    ui.close();
    ui.endInputScope(root_id);
    ui.close();
    return response;
}

fn requestClose(self: *const Dialog, frame: *Frame, reason: CloseReason) ?CloseReason {
    if (!self.is_open.*) return null;
    self.is_open.* = false;
    frame.requestRedraw();
    return reason;
}

fn clampAxisToMax(axis: Element.sizing.Axis, max_size: f32) Element.sizing.Axis {
    var out = axis;
    out.min = @min(out.min, max_size);
    out.max = @min(out.max, max_size);
    if (out.max < out.min) out.max = out.min;
    return out;
}
