const ui_mod = @import("../root.zig");
const Key = ui_mod.Key;
const Style = ui_mod.Style;
const Element = @import("layout").Element;
const Frame = ui_mod.Frame;

label: ?[]const u8 = null,
disabled: bool = false,
key: Key,
style: *const Style = &.{},
parts: Parts = .{},

pub const Parts = struct {
    label: *const Style = &.{},
};

pub const base = struct {
    pub const root: Style = .{
        .direction = .row,
        .@"align" = .center,
        .justify = .center,
        .padding = .xy(12, 6),
        .background = .accent,
        .foreground = .on_accent,
        .radius = .sm,
        .hover = &.{ .state_layer = 0.15 },
        .active = &.{ .state_layer = 0.25 },
        .disabled = &.{ .opacity = 0.5 },
        .transition = .{ .duration_ms = 100 },
    };
    pub const label: Style = .{};
};

const Button = @This();

pub const Response = struct {
    id: Element.Id,
    clicked: bool,
    hovered: bool,
};

pub fn interact(self: *const Button, frame: *Frame) !Response {
    const response = try self.openResponse(frame);
    try self.close(frame);
    return response;
}

pub fn open(self: *const Button, frame: *Frame) !Element.Id {
    return (try self.openResponse(frame)).id;
}

pub fn openResponse(self: *const Button, frame: *Frame) !Response {
    const ui = frame.ui();
    const id = self.key.hash();
    const st = ui.states(id, .{ .disabled = self.disabled });

    const root = try ui.openStyled(self.key, .{ .base = &base.root, .user = self.style }, st, .{
        .interactive = !self.disabled,
        .focusable = !self.disabled,
    });
    try ui.setAccessibility(root.id, .{
        .role = .button,
        .name = self.label orelse &.{},
        .state = .{ .disabled = self.disabled },
    });

    var clicked = false;
    if (!self.disabled) {
        const key_activate = ui.focused(root.id) and
            (ui.input.containsKey(.enter) or ui.input.containsKey(.kp_enter) or ui.input.containsKey(.space));
        clicked = ui.leftClicked(root.id, .within) or key_activate or ui.consumeAccessibilityAction(root.id, .click) != null;
        if (key_activate) ui.input.consumeKeyboard();
    }

    if (self.label) |label| {
        _ = try ui.styledText(self.key.indexed(1), label, .{ .base = &base.label, .user = self.parts.label }, st);
    }

    return .{ .id = root.id, .clicked = clicked, .hovered = st.hover };
}

pub fn close(_: *const Button, frame: *Frame) !void {
    frame.ui().close();
}
