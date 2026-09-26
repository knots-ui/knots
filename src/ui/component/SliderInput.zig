const std = @import("std");

const Element = @import("layout").Element;
const Frame = @import("../root.zig").Frame;
const ui_mod = @import("../root.zig");
const Key = ui_mod.Key;
const Style = ui_mod.Style;
const animation = ui_mod.animation;

value: *f32,
min: f32 = 0,
max: f32 = 1,
steps: f32 = 0,
key: Key,
style: *const Style = &.{},
parts: Parts = .{},

/// Style scopes drawn inside the single range decoration.
pub const Parts = struct {
    /// `height`, `background`, `radius`.
    track: *const Style = &.{},
    /// `background`; shares the track radius.
    fill: *const Style = &.{},
    /// `width` (diameter) and `background`.
    thumb: *const Style = &.{},
};

pub const base = struct {
    /// Height defaults to fit the track and the thumb.
    pub const root: Style = .{ .width = .grow() };
    pub const track: Style = .{ .height = .fixed(4), .background = .toned, .radius = .{ .fixed = 2 } };
    pub const fill: Style = .{ .background = .highlighted };
    pub const thumb: Style = .{ .width = .fixed(14), .background = .accented };
};

const TRACK_INDEX: usize = 1;
const FILL_INDEX: usize = 2;
const THUMB_INDEX: usize = 3;

const SliderInput = @This();

pub const Response = struct {
    id: Element.Id,
    changed: bool,
};

pub fn interact(self: *const SliderInput, frame: *Frame) !Response {
    const response = try self.openResponse(frame);
    try self.close(frame);
    return response;
}

pub fn open(self: *const SliderInput, frame: *Frame) !Element.Id {
    return (try self.openResponse(frame)).id;
}

/// Private for the same reason as `Checkbox.openResponse`: a slider is a leaf.
fn openResponse(self: *const SliderInput, frame: *Frame) !Response {
    const ui = frame.ui();
    const id = self.key.hash();
    var changed = false;

    const slider_state = try ui.state.getOrCreate(.slider, ui.allocator, id);

    if (ui.pressing(id) and ui.input.mouseButton(.left).down) {
        const bounds = slider_state.bounds;
        if (bounds.w() > 0) {
            const mx: f32 = @floatCast(ui.input.mouse_pos[0]);
            const t = std.math.clamp((mx - bounds.x()) / bounds.w(), 0, 1);
            const new_value = self.steppedValue(self.min + t * (self.max - self.min));
            if (new_value != self.value.*) {
                self.value.* = new_value;
                changed = true;
            }
        }
    }
    if (ui.focused(id)) {
        const range = self.max - self.min;
        const abs_range = @abs(range);
        const step = if (self.steps > 0) self.steps else abs_range / 100.0;
        var next_value: ?f32 = null;
        if (ui.input.containsKey(.home)) {
            next_value = self.min;
        } else if (ui.input.containsKey(.end)) {
            next_value = self.max;
        } else if (step > 0 and (ui.input.containsKey(.left) or ui.input.containsKey(.down))) {
            next_value = self.value.* - step;
        } else if (step > 0 and (ui.input.containsKey(.right) or ui.input.containsKey(.up))) {
            next_value = self.value.* + step;
        }
        if (next_value) |v| {
            const new_value = self.steppedValue(v);
            if (new_value != self.value.*) {
                self.value.* = new_value;
                changed = true;
            }
            ui.input.consumeKeyboard();
        }
    }

    const step = if (self.steps > 0) self.steps else @abs(self.max - self.min) / 100.0;
    var requested: ?f32 = null;
    if (ui.consumeAccessibilityAction(id, .increment) != null) requested = self.value.* + step;
    if (ui.consumeAccessibilityAction(id, .decrement) != null) requested = self.value.* - step;
    if (ui.consumeAccessibilityAction(id, .set_value)) |action| {
        if (action.value_number) |number| {
            if (std.math.isFinite(number)) requested = @floatCast(number);
        }
    }
    if (requested) |number| {
        const next = self.steppedValue(std.math.clamp(number, @min(self.min, self.max), @max(self.min, self.max)));
        if (self.value.* != next) {
            self.value.* = next;
            changed = true;
        }
    }

    const range = self.max - self.min;
    const display_value = self.steppedValue(self.value.*);
    const progress: f32 = if (range > 0) std.math.clamp((display_value - self.min) / range, 0, 1) else 0;

    const is_hovered = ui.hovering(id);
    const is_dragging = ui.pressing(id) and ui.input.mouseButton(.left).down;
    const opts: animation.Options = .{ .duration_ms = 100 };
    const hover_t = ui.anim(id, "hover", if (is_hovered) 1.0 else 0.0, opts);
    const drag_t = ui.anim(id, "drag", if (is_dragging) 1.0 else 0.0, opts);

    const st = ui.states(id, .{});
    const root = ui.resolveStyle(id, .{ .base = &base.root, .user = self.style }, st, null);
    const track = ui.resolveStyle(self.key.indexed(TRACK_INDEX).hash(), .{ .base = &base.track, .user = self.parts.track }, st, null);
    const fill = ui.resolveStyle(self.key.indexed(FILL_INDEX).hash(), .{ .base = &base.fill, .user = self.parts.fill }, st, null);
    const thumb = ui.resolveStyle(self.key.indexed(THUMB_INDEX).hash(), .{ .base = &base.thumb, .user = self.parts.thumb }, st, null);

    const track_height = fixedOr(track.layout.height, 4);
    const knob_radius = fixedOr(thumb.layout.width, 14) * 0.5;
    const knob_scale = 1.0 + 0.15 * hover_t + 0.20 * drag_t;
    const effective_knob_radius = knob_radius * knob_scale;

    const halo_alpha = 0.25 * hover_t + 0.40 * drag_t;
    const halo_r = knob_radius * (1.8 + 0.4 * drag_t);
    const knob_color = thumb.surface.color;
    const halo_color: [4]f32 = .{ knob_color[0], knob_color[1], knob_color[2], halo_alpha * knob_color[3] };

    var config = root.element(.{ .interactive = true, .focusable = true });
    if (config.height.kind == .fit) config.height = .fixed(@max(track_height, knob_radius * 2));

    const element_id = try ui.openWith(self.key, config, .{ .range = .{
        .progress = progress,
        .track_color = track.surface.color,
        .fill_color = fill.surface.color,
        .corner_radius = track.surface.corner_radius,
        .track_height = track_height,
        .knob_radius = effective_knob_radius,
        .knob_color = knob_color,
        .halo_radius = if (halo_alpha > 0.001) halo_r else 0,
        .halo_color = halo_color,
    } }, .{ .content = root.content });
    try ui.setAccessibility(element_id, .{
        .role = .slider,
        .state = .{
            .value_number = display_value,
            .min = self.min,
            .max = self.max,
        },
    });
    return .{ .id = element_id, .changed = changed };
}

pub fn close(_: *const SliderInput, frame: *Frame) !void {
    frame.ui().close();
}

fn fixedOr(axis: Element.sizing.Axis, fallback: f32) f32 {
    return if (axis.kind == .fixed) axis.value else fallback;
}

fn steppedValue(self: *const SliderInput, value: f32) f32 {
    const range = self.max - self.min;
    const clamped = if (range >= 0)
        std.math.clamp(value, self.min, self.max)
    else
        std.math.clamp(value, self.max, self.min);

    if (self.steps <= 0 or range <= 0) return clamped;

    const snapped = self.min + @round((clamped - self.min) / self.steps) * self.steps;
    return std.math.clamp(snapped, self.min, self.max);
}
