const std = @import("std");

const App = @import("knots").App;
const Element = @import("layout").Element;
const Grid = @import("layout").Grid;
const math = @import("math");
const ui_mod = @import("ui");

const Color = ui_mod.Color;
const Decoration = ui_mod.Decoration;
const Key = ui_mod.Key;
const Size = ui_mod.Size;
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

@"align": Element.Align = .start,
justify: Element.Justify = .start,
width: Element.sizing.Axis = .fit(),
height: Element.sizing.Axis = .fit(),
padding: Element.Padding = .init(0, 0, 0, 0),
dir: Element.Direction = .row,
overflow: Element.Overflow = .visible,
position: Element.Position = .static,
gap: f32 = 8,
style: Style = .{},
grid_template: ?Grid.Template = null,
grid_placement: ?Grid.Placement = null,

delay_ms: u32 = 450,
placement: PlacementKind = .top,
z_index: u8 = 10,
popup_padding: Element.Padding = .init(6, 8, 6, 8),
popup_style: Style = .{ .color = .elevated, .corner_radius = .sm, .border_color = .toned, .border_width = .all(1) },
popup_text_size: Size.Input = .xs,
popup_text_color: Color.Input = .text,
popup_font: ?[]const u8 = null,
popup_max_width: f32 = 260,

const Tooltip = @This();
const POPUP_INDEX: usize = 1;
const TEXT_INDEX: usize = 2;

pub fn open(self: *const Tooltip, app: *App) !Element.Id {
    const ui = &app.ui;
    const id = self.key.hash();
    _ = try ui.state.getOrCreate(.tooltip, ui.allocator, id);

    const decoration: Decoration = if (self.style.hasDecoration())
        .{ .rect = self.style.toRect(&ui.theme) }
    else
        .none;

    return try ui.open(self.key, .{
        .alignment = self.@"align",
        .justify = self.justify,
        .width = self.width,
        .height = self.height,
        .padding = self.padding,
        .overflow = self.overflow,
        .position = self.position,
        .direction = self.dir,
        .gap = self.gap,
        .interactive = true,
        .grid_template = self.grid_template,
        .grid_placement = self.grid_placement,
    }, decoration);
}

pub fn close(self: *const Tooltip, app: *App) !void {
    const ui = &app.ui;
    const id = self.key.hash();
    ui.close();

    const s = try ui.state.getOrCreate(.tooltip, ui.allocator, id);
    const hovered = ui.isHoveredWithin(id);
    const focused = ui.isFocusedWithin(id);

    if (!hovered and !focused) {
        s.hover_started_ms = null;
        return;
    }

    if (!focused and !(try hoverDelayElapsed(app, s, self.delay_ms))) return;

    try self.renderPopup(app, s);
}

fn hoverDelayElapsed(app: *App, s: *State.Tooltip, delay_ms: u32) !bool {
    const now = app.ui.input.now_ms;
    if (s.hover_started_ms == null) {
        s.hover_started_ms = now;
        try app.signal(.redraw);
        return delay_ms == 0;
    }

    const elapsed = now - s.hover_started_ms.?;
    if (elapsed >= @as(i64, @intCast(delay_ms))) return true;

    try app.signal(.redraw);
    return false;
}

fn renderPopup(self: *const Tooltip, app: *App, s: *State.Tooltip) !void {
    const ui = &app.ui;
    const popup_key = self.key.indexed(POPUP_INDEX);
    const popup_id = popup_key.hash();

    _ = try ui.state.getOrCreate(.measured, ui.allocator, popup_id);
    const measured_box = if (ui.state.get(.measured, popup_id)) |m| m.box else math.Rect.zero;
    if (!sameRect(s.popup_box, measured_box)) {
        s.popup_box = measured_box;
        try app.signal(.redraw);
    }

    const fallback_size = try self.fallbackPopupSize(ui, s.viewport_box);
    const measured_size = if (measured_box.w() > 0 and measured_box.h() > 0)
        measured_box.size()
    else
        fallback_size;

    const p = placePopup(s.viewport_box, s.anchor_box, measured_size, self.placement, self.gap);

    const tooltip_id = try ui.openRoot(popup_key, p.x, p.y, .{
        .direction = .row,
        .width = .fixed(p.width),
        .height = .{ .kind = .fit, .max = @max(p.height, s.viewport_box.h()) },
        .z_index = self.z_index,
        .padding = self.popup_padding,
        .overflow = .hidden,
    }, .{ .rect = self.popup_style.toRect(&ui.theme) });
    try ui.setAccessibility(tooltip_id, .{
        .role = .tooltip,
        .name = self.content,
    });

    {
        var deco = try ui.textDecoration(self.content, self.popup_text_size.resolve(), self.popup_font, true);
        deco.text.color = self.popup_text_color.resolve(&ui.theme);
        _ = try ui.open(self.key.indexed(TEXT_INDEX), .{ .width = .grow(), .height = .fit() }, deco);
        ui.close();
    }

    ui.close();
}

fn fallbackPopupSize(self: *const Tooltip, ui: *ui_mod.UI, viewport: math.Rect) !math.Vec2 {
    const deco = try ui.textDecoration(self.content, self.popup_text_size.resolve(), self.popup_font, false);
    const pad_w = self.popup_padding.left() + self.popup_padding.right();
    const pad_h = self.popup_padding.top() + self.popup_padding.bottom();
    const viewport_w = if (viewport.w() > 0) viewport.w() else self.popup_max_width;

    return .{
        @max(0, @min(deco.text.intrinsic_w + pad_w, @min(self.popup_max_width, viewport_w))),
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
