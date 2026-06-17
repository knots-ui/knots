const std = @import("std");

const Element = @import("layout").Element;
const App = @import("knots").App;
const ui_mod = @import("ui");
const Color = ui_mod.Color;
const Key = ui_mod.Key;
const Radius = ui_mod.Radius;
const animation = ui_mod.animation;

value: *f32,
min: f32 = 0,
max: f32 = 1,
steps: f32 = 0,
width: Element.sizing.Axis = .grow(),
track_height: f32 = 4,
track_color: Color.Input = .toned,
fill_color: Color.Input = .highlighted,
corner_radius: Radius.Input = .{ .fixed = 2 },
knob_radius: f32 = 7,
knob_color: Color.Input = .accented,
onChange: ?*const fn (*App) anyerror!void = null,
key: Key,

const SliderInput = @This();

pub fn open(self: *const SliderInput, app: *App) !Element.Id {
    const ui = &app.ui;
    const id = self.key.hash();

    const slider_state = try ui.state.getOrCreate(.slider, ui.allocator, id);

    if (ui.pressing(id) and ui.input.mouse_left_down) {
        const bounds = slider_state.bounds;
        if (bounds.w() > 0) {
            const mx: f32 = @floatCast(ui.input.mouse_pos[0]);
            const t = std.math.clamp((mx - bounds.x()) / bounds.w(), 0, 1);
            const new_value = self.steppedValue(self.min + t * (self.max - self.min));
            if (new_value != self.value.*) {
                self.value.* = new_value;
                if (self.onChange) |cb| try cb(app);
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
                if (self.onChange) |cb| try cb(app);
            }
            ui.input.consumeKeyboard();
        }
    }

    const range = self.max - self.min;
    const display_value = self.steppedValue(self.value.*);
    const progress: f32 = if (range > 0) std.math.clamp((display_value - self.min) / range, 0, 1) else 0;

    const is_hovered = ui.hovering(id);
    const is_dragging = ui.pressing(id) and ui.input.mouse_left_down;
    const opts: animation.Options = .{ .duration_ms = 100 };
    const hover_t = ui.anim(id, "hover", if (is_hovered) 1.0 else 0.0, opts);
    const drag_t = ui.anim(id, "drag", if (is_dragging) 1.0 else 0.0, opts);

    const knob_scale = 1.0 + 0.15 * hover_t + 0.20 * drag_t;
    const effective_knob_radius = self.knob_radius * knob_scale;

    const halo_alpha = 0.25 * hover_t + 0.40 * drag_t;
    const halo_r = self.knob_radius * (1.8 + 0.4 * drag_t);
    const base_knob_color = self.knob_color.resolve(&ui.theme);
    const halo_color: [4]f32 = .{ base_knob_color[0], base_knob_color[1], base_knob_color[2], halo_alpha };

    const element_height = @max(self.track_height, self.knob_radius * 2);

    const element_id = try ui.open(self.key, .{
        .width = self.width,
        .height = .fixed(element_height),
        .interactive = true,
        .focusable = true,
    }, .{ .range = .{
        .progress = progress,
        .track_color = self.track_color.resolve(&ui.theme),
        .fill_color = self.fill_color.resolve(&ui.theme),
        .corner_radius = self.corner_radius.resolve(&ui.theme),
        .track_height = self.track_height,
        .knob_radius = effective_knob_radius,
        .knob_color = base_knob_color,
        .halo_radius = if (halo_alpha > 0.001) halo_r else 0,
        .halo_color = halo_color,
    } });
    try ui.setAccessibility(element_id, .{
        .role = .slider,
        .state = .{
            .value_number = display_value,
            .min = self.min,
            .max = self.max,
        },
    });
    return element_id;
}

pub fn close(_: *const SliderInput, app: *App) !void {
    app.ui.close();
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
