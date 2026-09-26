const ui_mod = @import("../root.zig");
const Frame = ui_mod.Frame;
const Decoration = ui_mod.Decoration;
const Key = ui_mod.Key;
const Style = ui_mod.Style;
const Element = @import("layout").Element;

checked: *bool,
label: ?[]const u8 = null,
key: Key,
style: *const Style = &.{},
parts: Parts = .{},

pub const Parts = struct {
    box: *const Style = &.{},
    /// `foreground` colors the check mark.
    indicator: *const Style = &.{},
    label: *const Style = &.{},
};

pub const base = struct {
    pub const root: Style = .{ .direction = .row, .@"align" = .center, .gap = 8 };
    pub const box: Style = .{
        .width = .fixed(18),
        .height = .fixed(18),
        .background = .muted,
        .radius = .sm,
        .border_width = .all(1),
        .border_color = .toned,
        .hover = &.{ .border_color = .accent },
        .focus = &.{ .border_color = .accent },
        .checked = &.{ .background = .accent, .border_color = .accent },
        .transition = .{ .duration_ms = 100 },
    };
    pub const indicator: Style = .{ .width = .grow(), .height = .grow(), .foreground = .on_accent };
    pub const label: Style = .{};
};

const Checkbox = @This();

const BOX_INDEX: usize = 1;
const LABEL_INDEX: usize = 2;
const INDICATOR_INDEX: usize = 3;

pub const Response = struct {
    id: Element.Id,
    changed: bool,
};

pub fn interact(self: *const Checkbox, frame: *Frame) !Response {
    const response = try self.openResponse(frame);
    try self.close(frame);
    return response;
}

pub fn open(self: *const Checkbox, frame: *Frame) !Element.Id {
    return (try self.openResponse(frame)).id;
}

/// Private: a leaf has nothing to nest, so `interact` is the whole interaction.
/// Containers like `Button` expose `openResponse` instead.
fn openResponse(self: *const Checkbox, frame: *Frame) !Response {
    const ui = frame.ui();
    const id = self.key.hash();

    const key_activate = ui.focused(id) and
        (ui.input.containsKey(.space) or ui.input.containsKey(.enter) or ui.input.containsKey(.kp_enter));
    const changed = ui.leftClicked(id, .within) or key_activate or ui.consumeAccessibilityAction(id, .click) != null;
    if (changed) {
        self.checked.* = !self.checked.*;
        if (key_activate) ui.input.consumeKeyboard();
    }

    const st = ui.states(id, .{ .checked = self.checked.* });
    const root = ui.resolveStyle(id, .{ .base = &base.root, .user = self.style }, st, null);
    const box = ui.resolveStyle(self.key.indexed(BOX_INDEX).hash(), .{ .base = &base.box, .user = self.parts.box }, st, null);
    var config = root.element(.{ .interactive = true, .focusable = true });
    const box_h = if (box.layout.height.kind == .fixed) box.layout.height.value else 0;
    config.height.min = @max(config.height.min, @max(box_h, try ui.lineHeight(root.content.font_size, root.content.font)));
    _ = try ui.openResolved(self.key, &root, config, null);
    try ui.setAccessibility(id, .{
        .role = .checkbox,
        .name = self.label orelse &.{},
        .state = .{ .checked = self.checked.* },
    });

    return .{ .id = id, .changed = changed };
}

pub fn close(self: *const Checkbox, frame: *Frame) !void {
    const ui = frame.ui();
    const id = self.key.hash();
    const st = ui.states(id, .{ .checked = self.checked.* });

    const box = try ui.openStyled(self.key.indexed(BOX_INDEX), .{ .base = &base.box, .user = self.parts.box }, st, .{});
    {
        const indicator = ui.resolveStyle(self.key.indexed(INDICATOR_INDEX).hash(), .{ .base = &base.indicator, .user = self.parts.indicator }, st, null);
        const w = if (box.resolved.layout.width.kind == .fixed) box.resolved.layout.width.value else 18;
        const h = if (box.resolved.layout.height.kind == .fixed) box.resolved.layout.height.value else 18;
        const color = indicator.content.foreground;
        const cmds: []const Decoration.DrawCmd = if (self.checked.*) try frame.arena().dupe(Decoration.DrawCmd, &[_]Decoration.DrawCmd{
            .{ .line = .{ .from = .{ w * 0.28, h * 0.53 }, .to = .{ w * 0.43, h * 0.68 }, .color = color, .thickness = 2 } },
            .{ .line = .{ .from = .{ w * 0.43, h * 0.68 }, .to = .{ w * 0.74, h * 0.34 }, .color = color, .thickness = 2 } },
        }) else &.{};
        _ = try ui.openWith(self.key.indexed(INDICATOR_INDEX), indicator.element(.{}), .{ .canvas = .{ .cmds = cmds } }, .{ .content = indicator.content });
        ui.close();
    }
    ui.close();

    if (self.label) |label| {
        _ = try ui.styledText(self.key.indexed(LABEL_INDEX), label, .{ .base = &base.label, .user = self.parts.label }, st);
    }

    ui.close();
}
