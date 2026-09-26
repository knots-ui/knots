const std = @import("std");

const Frame = @import("../root.zig").Frame;
const Element = @import("layout").Element;
const math = @import("math");
const ui_mod = @import("../root.zig");

const Decoration = ui_mod.Decoration;
const Key = ui_mod.Key;
const Style = ui_mod.Style;
const animation = ui_mod.animation;

pub const CloseReason = enum {
    close_button,
    escape,
};

is_open: *bool,
title: []const u8,
key: Key,

initial_size: math.Vec2 = .{ 480, 320 },
min_size: math.Vec2 = .{ 240, 140 },
max_size: ?math.Vec2 = null,
initial_position: ?math.Vec2 = null,
bounds: ?math.Rect = null,
resizable: bool = true,
closable: bool = true,
close_on_escape: bool = true,
maximizable: bool = true,

/// The window frame.
style: *const Style = &.{},
parts: Parts = .{},

pub const Parts = struct {
    /// A fixed `height` sets the bar height; `font_size` and `foreground` style the title.
    title_bar: *const Style = &.{},
    /// Maximize and close buttons; `foreground` colors the icons.
    title_button: *const Style = &.{},
    /// Hosts the children.
    content: *const Style = &.{},
};

pub const base = struct {
    pub const root: Style = .{
        .direction = .column,
        .overflow = .hidden,
        .background = .elevated,
        .foreground = .text,
        .radius = .md,
        .border_width = .all(1),
        .border_color = .toned,
    };
    pub const title_bar: Style = .{
        .width = .grow(),
        .height = .fixed(36),
        .direction = .row,
        .@"align" = .center,
        .padding = .xy(12, 0),
        .background = .muted,
    };
    pub const title_button: Style = .{
        .@"align" = .center,
        .justify = .center,
        .hover = &.{ .foreground = .accent },
        .transition = .{ .duration_ms = 100 },
    };
    pub const content: Style = .{
        .width = .grow(),
        .height = .grow(),
        .direction = .column,
        .overflow = .scroll_y,
        .padding = .all(12),
    };
};

const FloatingWindow = @This();

pub const OpenResponse = struct {
    id: Element.Id,
    close_reason: ?CloseReason,
};

const TitleIcon = enum {
    maximize,
    restore,
    close,
};

const TITLE_INDEX: usize = 1;
const TITLE_TEXT_INDEX: usize = 2;
const MAXIMIZE_INDEX: usize = 3;
const MAXIMIZE_ICON_INDEX: usize = 4;
const CLOSE_INDEX: usize = 5;
const CLOSE_ICON_INDEX: usize = 6;
const CONTENT_INDEX: usize = 7;
const RESIZE_INDEX: usize = 8;
const CASCADE_STEP: f32 = 24;
const CASCADE_COUNT: u32 = 8;
const RESIZE_HIT_SIZE: f32 = 20;
const WINDOW_ANIM_OPTIONS: animation.Options = .{ .duration_ms = 180, .ease = .ease_out_cubic };

pub fn open(self: *const FloatingWindow, frame: *Frame) !Element.Id {
    return (try self.openResponse(frame)).id;
}

pub fn openResponse(self: *const FloatingWindow, frame: *Frame) !OpenResponse {
    const ui = frame.ui();
    const id = self.key.hash();
    if (!self.is_open.*) {
        ui.state.hideFloatingWindow(id);
        return .{ .id = Element.INVALID_ID, .close_reason = null };
    }

    const title_id = self.key.indexed(TITLE_INDEX).hash();
    const maximize_id = self.key.indexed(MAXIMIZE_INDEX).hash();
    const close_id = self.key.indexed(CLOSE_INDEX).hash();
    const resize_id = self.key.indexed(RESIZE_INDEX).hash();
    const state = try ui.state.touchFloatingWindow(id);
    const title_bar = ui.resolveStyle(title_id, .{ .base = &base.title_bar, .user = self.parts.title_bar }, .{}, null);
    const title_bar_height = titleBarHeight(&title_bar);
    const input = frame.input();
    const viewport_size = input.logical_extent;
    const viewport = math.Rect.init(0, 0, @floatFromInt(viewport_size.width), @floatFromInt(viewport_size.height));
    var window_bounds = if (self.bounds) |b| viewport.intersect(b) else viewport;
    const bounds_size = @max(math.splat(math.Vec2, 1), @min(window_bounds.size(), @max(viewport.size(), math.splat(math.Vec2, 1))));
    const viewport_min = viewport.min();
    const bounds_max = @max(viewport_min, viewport.max() - bounds_size);
    window_bounds.setW(bounds_size[0]);
    window_bounds.setH(bounds_size[1]);
    window_bounds.setX(std.math.clamp(window_bounds.x(), viewport_min[0], bounds_max[0]));
    window_bounds.setY(std.math.clamp(window_bounds.y(), viewport_min[1], bounds_max[1]));

    if (!state.initialized) {
        state.size = clampSizeToBounds(self.initial_size, self.effectiveMinSize(title_bar_height), self.max_size, window_bounds);
        if (self.initial_position) |position| {
            state.position = position;
        } else {
            const offset: f32 = @floatFromInt((state.stack_order - 1) % CASCADE_COUNT);
            state.position = window_bounds.min() + (window_bounds.size() - state.size) * math.splat(math.Vec2, 0.5) + math.splat(math.Vec2, offset * CASCADE_STEP);
        }
        state.position = clampPosition(state.position, state.size, window_bounds);
        state.restore_position = state.position;
        state.restore_size = state.size;
        state.render_position = state.position;
        state.render_size = state.size;
        state.initialized = true;
    }

    if (ui.leftPressed(id, .root))
        try ui.state.raiseFloatingWindow(id);

    if (state.maximized and !self.maximizable) {
        state.maximized = false;
        state.size = clampSizeToBounds(state.restore_size, self.effectiveMinSize(title_bar_height), self.max_size, window_bounds);
        state.position = clampPosition(state.restore_position, state.size, window_bounds);
        frame.requestRedraw();
    }

    const maximize_from_keyboard = self.maximizable and ui.focused(maximize_id) and activationKeyPressed(ui);
    if (self.maximizable and (ui.leftClicked(maximize_id, .exact) or maximize_from_keyboard)) {
        if (maximize_from_keyboard) ui.input.consumeKeyboard();
        if (state.maximized) {
            state.maximized = false;
            state.size = clampSizeToBounds(state.restore_size, self.effectiveMinSize(title_bar_height), self.max_size, window_bounds);
            state.position = clampPosition(state.restore_position, state.size, window_bounds);
        } else {
            state.restore_position = state.position;
            state.restore_size = state.size;
            state.size = clampSizeToBounds(window_bounds.size(), self.effectiveMinSize(title_bar_height), self.max_size, window_bounds);
            state.position = clampPosition(window_bounds.min(), state.size, window_bounds);
            state.dragging = false;
            state.resizing = false;
            state.maximized = true;
        }
        frame.requestRedraw();
    }

    const close_from_keyboard = self.closable and ui.focused(close_id) and
        activationKeyPressed(ui);
    if (self.closable and (ui.leftClicked(close_id, .exact) or close_from_keyboard)) {
        if (close_from_keyboard) ui.input.consumeKeyboard();
        const reason = self.requestClose(frame, .close_button);
        return .{ .id = Element.INVALID_ID, .close_reason = reason };
    }

    const left = ui.input.mouseButton(.left);
    const mouse = math.Vec2{ @floatCast(ui.input.mouse_pos[0]), @floatCast(ui.input.mouse_pos[1]) };
    const hovering_maximize = self.maximizable and ui.hovering(maximize_id);
    const hovering_close = self.closable and ui.hovering(close_id);
    if (!state.maximized and self.resizable and ui.leftPressed(resize_id, .exact)) {
        state.position = state.render_position;
        state.size = state.render_size;
        state.resizing = true;
        state.dragging = false;
        state.resize_offset = state.position + state.size - mouse;
    } else if (!state.maximized and left.pressed and ui.hovering(title_id) and !hovering_maximize and !hovering_close) {
        state.position = state.render_position;
        state.dragging = true;
        state.resizing = false;
        state.drag_offset = mouse - state.position;
    }

    if (!left.down) {
        state.dragging = false;
        state.resizing = false;
    } else if (state.resizing) {
        state.size = mouse + state.resize_offset - state.position;
    } else if (state.dragging) {
        state.position = mouse - state.drag_offset;
    }
    state.size = clampSizeToBounds(state.size, self.effectiveMinSize(title_bar_height), self.max_size, window_bounds);
    state.position = clampPosition(state.position, state.size, window_bounds);
    if (state.maximized) {
        state.size = clampSizeToBounds(window_bounds.size(), self.effectiveMinSize(title_bar_height), self.max_size, window_bounds);
        state.position = clampPosition(window_bounds.min(), state.size, window_bounds);
    }
    const rect_anim_options: animation.Options = if (state.dragging or state.resizing)
        .{ .duration_ms = 0 }
    else
        WINDOW_ANIM_OPTIONS;
    state.render_position = .{
        ui.anim(id, "x", state.position[0], rect_anim_options),
        ui.anim(id, "y", state.position[1], rect_anim_options),
    };
    state.render_size = .{
        ui.anim(id, "w", state.size[0], rect_anim_options),
        ui.anim(id, "h", state.size[1], rect_anim_options),
    };

    if (state.resizing or (!state.maximized and self.resizable and ui.hovering(resize_id)))
        ui.requestCursor(.resize_diagonal_nw_se)
    else if (!state.maximized and (state.dragging or (ui.hovering(title_id) and !hovering_maximize and !hovering_close)))
        ui.requestCursor(.move);

    const z_index = try ui.state.floatingWindowZ(id);
    const root = ui.resolveStyle(id, .{ .base = &base.root, .user = self.style }, .{}, null);
    var root_config = root.element(.{ .interactive = true });
    root_config.width = .fixed(state.render_size[0]);
    root_config.height = .fixed(state.render_size[1]);
    root_config.z_index = z_index.index();
    const root_id = try ui.openResolved(self.key, &root, root_config, .{ state.render_position[0], state.render_position[1] });
    try ui.setAccessibility(root_id, .{
        .role = .dialog,
        .name = self.title,
        .state = .{ .expanded = true },
    });

    {
        // Re-resolve inside the frame so the title bar inherits the frame's content.
        const bar = ui.resolveStyle(title_id, .{ .base = &base.title_bar, .user = self.parts.title_bar }, .{}, null);
        const bar_config = bar.element(.{ .interactive = true });
        _ = try ui.openResolved(self.key.indexed(TITLE_INDEX), &bar, bar_config, null);
    }

    const bar_content = ui.contents.items[ui.currentSlot()];
    var title_decoration = try ui.textDecoration(self.title, bar_content.font_size, bar_content.font, false);
    title_decoration.text.color = bar_content.foreground;
    _ = try ui.open(self.key.indexed(TITLE_TEXT_INDEX), .{
        .width = .grow(),
        .height = .fit(),
    }, title_decoration);
    ui.close();

    if (self.maximizable) {
        try self.openTitleButton(frame, MAXIMIZE_INDEX, if (state.maximized) "Restore" else "Maximize", title_bar_height);
        try self.openTitleIcon(frame, if (state.maximized) .restore else .maximize, title_bar_height);
        ui.close();
    }

    if (self.closable) {
        try self.openTitleButton(frame, CLOSE_INDEX, "Close", title_bar_height);
        try self.openTitleIcon(frame, .close, title_bar_height);
        ui.close();
    }
    ui.close();

    _ = try ui.openStyled(self.key.indexed(CONTENT_INDEX), .{ .base = &base.content, .user = self.parts.content }, .{}, .{});
    return .{ .id = root_id, .close_reason = null };
}

pub fn close(self: *const FloatingWindow, frame: *Frame) !void {
    _ = try self.closeResponse(frame);
}

pub fn closeResponse(self: *const FloatingWindow, frame: *Frame) !?CloseReason {
    const ui = frame.ui();
    const id = self.key.hash();
    if (ui.layout_ctx.slotForId(id) == null) return null;
    const state = ui.state.get(.floating_window, id) orelse return null;

    ui.close();
    var response: ?CloseReason = null;
    if (self.close_on_escape and ui.state.isFrontFloatingWindow(id) and ui.input.containsKey(.escape)) {
        ui.input.consumeKeyboard();
        response = self.requestClose(frame, .escape);
    }

    if (self.resizable and !state.maximized) {
        var hit_config: Element.Config = .at(state.render_size[0] - RESIZE_HIT_SIZE, state.render_size[1] - RESIZE_HIT_SIZE, RESIZE_HIT_SIZE, RESIZE_HIT_SIZE);
        hit_config.interactive = true;
        _ = try ui.open(self.key.indexed(RESIZE_INDEX), hit_config, .none);
        ui.close();
    }
    ui.close();
    return response;
}

fn openTitleButton(self: *const FloatingWindow, frame: *Frame, comptime index: usize, name: []const u8, title_bar_height: f32) !void {
    const ui = frame.ui();
    const button_id = self.key.indexed(index).hash();
    const button_size = @max(1, title_bar_height - 8);
    const button = ui.resolveStyle(button_id, .{ .base = &base.title_button, .user = self.parts.title_button }, ui.states(button_id, .{}), null);
    var config = button.element(.{ .interactive = true, .focusable = true });
    if (config.width.kind == .fit) config.width = .fixed(button_size);
    if (config.height.kind == .fit) config.height = .fixed(button_size);
    _ = try ui.openResolved(self.key.indexed(index), &button, config, null);
    try ui.setAccessibility(button_id, .{ .role = .button, .name = name });
}

fn openTitleIcon(self: *const FloatingWindow, frame: *Frame, icon: TitleIcon, title_bar_height: f32) !void {
    const ui = frame.ui();
    // The icon draws in the title button's (transitioned) foreground.
    const icon_color = ui.contents.items[ui.currentSlot()].foreground;
    const icon_size = @max(10, title_bar_height * 0.34);
    const cmds = try frame.arena().alloc(Decoration.DrawCmd, switch (icon) {
        .close => 2,
        .maximize => 4,
        .restore => 8,
    });
    switch (icon) {
        .close => {
            cmds[0] = .{ .line = .{
                .from = .{ icon_size * 0.25, icon_size * 0.25 },
                .to = .{ icon_size * 0.75, icon_size * 0.75 },
                .color = icon_color,
                .thickness = 1.75,
            } };
            cmds[1] = .{ .line = .{
                .from = .{ icon_size * 0.75, icon_size * 0.25 },
                .to = .{ icon_size * 0.25, icon_size * 0.75 },
                .color = icon_color,
                .thickness = 1.75,
            } };
        },
        .maximize => appendSquareIcon(cmds[0..4], icon_size, 0.22, 0.22, 0.56, icon_color),
        .restore => {
            appendSquareIcon(cmds[0..4], icon_size, 0.18, 0.34, 0.48, icon_color);
            appendSquareIcon(cmds[4..8], icon_size, 0.34, 0.18, 0.48, icon_color);
        },
    }
    _ = try ui.open(self.key.indexed(switch (icon) {
        .close => CLOSE_ICON_INDEX,
        .maximize, .restore => MAXIMIZE_ICON_INDEX,
    }), .{
        .width = .fixed(icon_size),
        .height = .fixed(icon_size),
    }, .{ .canvas = .{ .cmds = cmds } });
    ui.close();
}

fn effectiveMinSize(self: *const FloatingWindow, title_bar_height: f32) math.Vec2 {
    return .{ self.min_size[0], @max(self.min_size[1], title_bar_height) };
}

fn titleBarHeight(title_bar: *const Style.Resolved) f32 {
    const h = title_bar.layout.height;
    return @max(1, if (h.kind == .fixed) h.value else 36);
}

fn requestClose(self: *const FloatingWindow, frame: *Frame, reason: CloseReason) ?CloseReason {
    if (!self.is_open.*) return null;
    self.is_open.* = false;
    frame.ui().state.hideFloatingWindow(self.key.hash());
    frame.requestRedraw();
    return reason;
}

fn activationKeyPressed(ui: *const ui_mod.UI) bool {
    return ui.input.containsKey(.enter) or ui.input.containsKey(.kp_enter) or ui.input.containsKey(.space);
}

fn clampSizeToBounds(size: math.Vec2, min_size: math.Vec2, max_size: ?math.Vec2, bounds: math.Rect) math.Vec2 {
    const bounds_size = @max(bounds.size(), math.splat(math.Vec2, 1));
    const bounded_min = @min(@max(min_size, math.splat(math.Vec2, 1)), bounds_size);
    const maximum = if (max_size) |m| @min(m, bounds_size) else bounds_size;
    const effective_max = @max(maximum, bounded_min);
    return std.math.clamp(size, bounded_min, effective_max);
}

fn clampPosition(position: math.Vec2, size: math.Vec2, bounds: math.Rect) math.Vec2 {
    const min = bounds.min();
    const max = @max(min, bounds.max() - size);
    return .{
        std.math.clamp(position[0], min[0], max[0]),
        std.math.clamp(position[1], min[1], max[1]),
    };
}

fn appendSquareIcon(cmds: []Decoration.DrawCmd, icon_size: f32, x: f32, y: f32, size: f32, color: [4]f32) void {
    std.debug.assert(cmds.len == 4);
    const left = icon_size * x;
    const top = icon_size * y;
    const right = icon_size * (x + size);
    const bottom = icon_size * (y + size);
    cmds[0] = .{ .line = .{ .from = .{ left, top }, .to = .{ right, top }, .color = color, .thickness = 1.75 } };
    cmds[1] = .{ .line = .{ .from = .{ right, top }, .to = .{ right, bottom }, .color = color, .thickness = 1.75 } };
    cmds[2] = .{ .line = .{ .from = .{ right, bottom }, .to = .{ left, bottom }, .color = color, .thickness = 1.75 } };
    cmds[3] = .{ .line = .{ .from = .{ left, bottom }, .to = .{ left, top }, .color = color, .thickness = 1.75 } };
}
