const std = @import("std");

const Frame = @import("../root.zig").Frame;
const Element = @import("layout").Element;
const math = @import("math");
const ui_mod = @import("../root.zig");

const Key = ui_mod.Key;
const State = ui_mod.State;
const Style = ui_mod.Style;

pub const PlacementKind = enum {
    top,
    bottom,
    left,
    right,
};

pub const Placement = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

key: Key,
content: []const u8,
delay_ms: u32 = 450,
placement: PlacementKind = .top,
/// The trigger: wraps the children.
style: *const Style = &.{},
parts: Parts = .{},

pub const Parts = struct {
    /// `width.max` caps the popup width; `layer` sets its layer.
    popup: *const Style = &.{},
};

pub const base = struct {
    pub const root: Style = .{};
    pub const popup: Style = .{
        .width = .{ .kind = .fit, .max = 260 },
        .direction = .row,
        .padding = .init(6, 8, 6, 8),
        .overflow = .hidden,
        .layer = .popup,
        .background = .elevated,
        .foreground = .text,
        .radius = .sm,
        .border_width = .all(1),
        .border_color = .toned,
        .font_size = .xs,
    };
};

/// Distance between the trigger and the popup.
const popup_offset: f32 = 8;

const Tooltip = @This();
const POPUP_INDEX: usize = 1;
const TEXT_INDEX: usize = 2;

pub fn open(self: *const Tooltip, frame: *Frame) !Element.Id {
    const ui = frame.ui();
    const id = self.key.hash();
    _ = try ui.state.getOrCreate(.tooltip, ui.allocator, id);
    return (try ui.openStyled(self.key, .{ .base = &base.root, .user = self.style }, .{}, .{ .interactive = true })).id;
}

pub fn close(self: *const Tooltip, frame: *Frame) !void {
    const ui = frame.ui();
    const id = self.key.hash();
    const content = ui.contents.items[ui.currentSlot()];
    ui.close();

    const s = try ui.state.getOrCreate(.tooltip, ui.allocator, id);
    const hovered = ui.isHoveredWithin(id);
    const focused = ui.isFocusedWithin(id);

    if (!hovered and !focused) {
        s.hover_started_ms = null;
        return;
    }

    if (!focused and !(try hoverDelayElapsed(frame, s, self.delay_ms))) return;

    try self.renderPopup(frame, s, &content);
}

fn hoverDelayElapsed(frame: *Frame, s: *State.Tooltip, delay_ms: u32) !bool {
    const now = frame.ui().input.now_ms;
    if (s.hover_started_ms == null) {
        s.hover_started_ms = now;
        frame.requestRedraw();
        return delay_ms == 0;
    }

    const elapsed = now - s.hover_started_ms.?;
    if (elapsed >= @as(i64, @intCast(delay_ms))) return true;

    frame.requestRedraw();
    return false;
}

fn renderPopup(self: *const Tooltip, frame: *Frame, s: *State.Tooltip, parent: *const Style.Content) !void {
    const ui = frame.ui();
    const popup_key = self.key.indexed(POPUP_INDEX);
    const popup_id = popup_key.hash();
    const popup = ui.resolveStyle(popup_id, .{ .base = &base.popup, .user = self.parts.popup }, .{}, parent);

    _ = try ui.state.getOrCreate(.measured, ui.allocator, popup_id);
    const measured_box = if (ui.state.get(.measured, popup_id)) |m| m.box else math.Rect.zero;
    if (!sameRect(s.popup_box, measured_box)) {
        s.popup_box = measured_box;
        frame.requestRedraw();
    }

    const fallback_size = try self.fallbackPopupSize(ui, &popup, s.viewport_box);
    const measured_size = if (measured_box.w() > 0 and measured_box.h() > 0)
        measured_box.size()
    else
        fallback_size;

    const p = placePopup(s.viewport_box, s.anchor_box, measured_size, self.placement, popup_offset);

    var config = popup.element(.{});
    config.width = .fixed(p.width);
    config.height = .{ .kind = .fit, .max = @max(p.height, s.viewport_box.h()) };
    const tooltip_id = try ui.openResolved(popup_key, &popup, config, .{ p.x, p.y });
    try ui.setAccessibility(tooltip_id, .{
        .role = .tooltip,
        .name = self.content,
    });

    {
        var deco = try ui.textDecoration(self.content, popup.content.font_size, popup.content.font, true);
        deco.text.color = popup.content.foreground;
        _ = try ui.open(self.key.indexed(TEXT_INDEX), .{ .width = .grow(), .height = .fit() }, deco);
        ui.close();
    }

    ui.close();
}

fn fallbackPopupSize(self: *const Tooltip, ui: *ui_mod.UI, popup: *const Style.Resolved, viewport: math.Rect) !math.Vec2 {
    const deco = try ui.textDecoration(self.content, popup.content.font_size, popup.content.font, false);
    const padding = popup.layout.padding;
    const pad_w = padding.left() + padding.right();
    const pad_h = padding.top() + padding.bottom();
    const max_width = popup.layout.width.max;
    const viewport_w = if (viewport.w() > 0) viewport.w() else max_width;

    return .{
        @max(0, @min(deco.text.intrinsic_w + pad_w, @min(max_width, viewport_w))),
        @max(0, deco.text.intrinsic_h + pad_h),
    };
}

pub fn placePopup(viewport: math.Rect, anchor: math.Rect, requested_size: math.Vec2, preferred: PlacementKind, gap: f32) Placement {
    const viewport_w = @max(0, viewport.w());
    const viewport_h = @max(0, viewport.h());
    const width = @min(@max(0, requested_size[0]), viewport_w);
    const height = @min(@max(0, requested_size[1]), viewport_h);

    const left = viewport.x();
    const top = viewport.y();
    const right = left + viewport_w;
    const bottom = top + viewport_h;

    const resolved = switch (preferred) {
        .top => if (anchor.y() - gap - height < top and bottom - (anchor.y() + anchor.h() + gap) > anchor.y() - gap - top) PlacementKind.bottom else .top,
        .bottom => if (anchor.y() + anchor.h() + gap + height > bottom and anchor.y() - gap - top > bottom - (anchor.y() + anchor.h() + gap)) PlacementKind.top else .bottom,
        .left => if (anchor.x() - gap - width < left and right - (anchor.x() + anchor.w() + gap) > anchor.x() - gap - left) PlacementKind.right else .left,
        .right => if (anchor.x() + anchor.w() + gap + width > right and anchor.x() - gap - left > right - (anchor.x() + anchor.w() + gap)) PlacementKind.left else .right,
    };

    const raw_x = switch (resolved) {
        .top, .bottom => anchor.x() + anchor.w() * 0.5 - width * 0.5,
        .left => anchor.x() - gap - width,
        .right => anchor.x() + anchor.w() + gap,
    };
    const raw_y = switch (resolved) {
        .top => anchor.y() - gap - height,
        .bottom => anchor.y() + anchor.h() + gap,
        .left, .right => anchor.y() + anchor.h() * 0.5 - height * 0.5,
    };

    return .{
        .x = clampAxis(raw_x, left, right - width),
        .y = clampAxis(raw_y, top, bottom - height),
        .width = width,
        .height = height,
    };
}

fn clampAxis(value: f32, min: f32, max: f32) f32 {
    if (max <= min) return min;
    return std.math.clamp(value, min, max);
}

fn sameRect(a: math.Rect, b: math.Rect) bool {
    return a.x() == b.x() and
        a.y() == b.y() and
        a.w() == b.w() and
        a.h() == b.h();
}
