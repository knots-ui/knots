const ui_mod = @import("../root.zig");
const Element = @import("layout").Element;
const window_icon = @import("window_icon.zig");

const Frame = ui_mod.Frame;
const Key = ui_mod.Key;
const Style = ui_mod.Style;

title: []const u8 = "",
key: Key,
minimizable: bool = true,
maximizable: bool = true,
closable: bool = true,

style: *const Style = &.{},
parts: Parts = .{},

pub const Parts = struct {
    title: *const Style = &.{},
    button: *const Style = &.{},
    close_button: *const Style = &.{},
};

pub const base = struct {
    pub const root: Style = .{
        .width = .grow(),
        .height = .fixed(36),
        .direction = .row,
        .@"align" = .center,
        .gap = 8,
        .padding = .init(0, 0, 0, 12),
        .layer = .chrome,
        .background = .muted,
        .foreground = .text,
    };
    pub const title: Style = .{};
    pub const button: Style = .{
        .width = .fixed(46),
        .height = .grow(),
        .@"align" = .center,
        .justify = .center,
        .hover = &.{ .state_layer = 0.1 },
        .active = &.{ .state_layer = 0.2 },
        .transition = .{ .duration_ms = 100 },
    };
    pub const close_button: Style = .{
        .width = .fixed(46),
        .height = .grow(),
        .@"align" = .center,
        .justify = .center,
        .hover = &.{ .background = .@"error", .foreground = .on_error },
        .active = &.{ .background = .@"error", .foreground = .on_error, .state_layer = 0.2 },
        .transition = .{ .duration_ms = 100 },
    };
};

const TitleBar = @This();

const TITLE_INDEX: usize = 1;
const INSET_INDEX: usize = 2;
const SPACER_INDEX: usize = 3;
const MINIMIZE_INDEX: usize = 4;
const MAXIMIZE_INDEX: usize = 6;
const CLOSE_INDEX: usize = 8;
const ICON_SIZE: f32 = 12;

pub fn open(self: *const TitleBar, frame: *Frame) !Element.Id {
    const ui = frame.ui();
    const root = try ui.openStyled(self.key, .{ .base = &base.root, .user = self.style }, .{}, .{ .interactive = true });
    try ui.beginInputScope(root.id, .chrome);
    try ui.markHitRegion(root.id, .caption);

    const inset = frame.nativeControlsWidth();
    if (inset > 0) {
        _ = try ui.open(self.key.indexed(INSET_INDEX), .{ .width = .fixed(inset) }, .none);
        ui.close();
    }
    if (self.title.len > 0) {
        _ = try ui.styledText(self.key.indexed(TITLE_INDEX), self.title, .{ .base = &base.title, .user = self.parts.title }, .{});
    }
    return root.id;
}

pub fn close(self: *const TitleBar, frame: *Frame) !void {
    const ui = frame.ui();
    _ = try ui.open(self.key.indexed(SPACER_INDEX), .{ .width = .grow() }, .none);
    ui.close();

    if (frame.nativeControlsWidth() == 0) {
        if (self.minimizable) {
            if (try self.windowButton(frame, MINIMIZE_INDEX, .minimize, "Minimize", &base.button, self.parts.button)) {
                frame.minimizeWindow();
            }
        }
        if (self.maximizable) {
            try self.maximizeButton(frame);
        }
        if (self.closable) {
            if (try self.windowButton(frame, CLOSE_INDEX, .close, "Close", &base.close_button, self.parts.close_button)) {
                frame.requestClose();
            }
        }
    }

    ui.endInputScope(self.key.hash());
    ui.close();
}

fn maximizeButton(self: *const TitleBar, frame: *Frame) !void {
    switch (frame.displayMode()) {
        .maximized => {
            if (try self.windowButton(frame, MAXIMIZE_INDEX, .restore, "Restore", &base.button, self.parts.button)) {
                frame.setDisplayMode(.windowed);
            }
        },
        .windowed, .fullscreen => {
            if (try self.windowButton(frame, MAXIMIZE_INDEX, .maximize, "Maximize", &base.button, self.parts.button)) {
                frame.setDisplayMode(.maximized);
            }
        },
    }
    try frame.ui().markHitRegion(self.key.indexed(MAXIMIZE_INDEX).hash(), .maximize);
}

fn windowButton(self: *const TitleBar, frame: *Frame, comptime index: usize, icon: window_icon.Icon, name: []const u8, base_style: *const Style, user: *const Style) !bool {
    const ui = frame.ui();
    const key = self.key.indexed(index);
    const id = key.hash();
    const button = try ui.openStyled(key, .{ .base = base_style, .user = user }, ui.states(id, .{}), .{ .interactive = true });
    try ui.setAccessibility(button.id, .{ .role = .button, .name = name });
    const clicked = ui.leftClicked(button.id, .within) or ui.consumeAccessibilityAction(button.id, .click) != null;
    try window_icon.open(frame, self.key.indexed(index + 1), icon, ICON_SIZE);
    ui.close();
    return clicked;
}
