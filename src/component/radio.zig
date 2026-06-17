const std = @import("std");

const App = @import("knots").App;
const Element = @import("layout").Element;
const ui_mod = @import("ui");
const Text = @import("Text.zig");

const Color = ui_mod.Color;
const Decoration = ui_mod.Decoration;
const Key = ui_mod.Key;
const Size = ui_mod.Size;
const Style = ui_mod.Style;

fn enumTagNames(comptime T: type, comptime values: []const T) [][]const u8 {
    comptime var names: [values.len][]const u8 = undefined;
    for (values, 0..) |v, i| {
        names[i] = @tagName(v);
    }
    const fixed: [values.len][]const u8 = names;
    return @constCast(&fixed);
}

pub fn defaultValues(comptime T: type) []const T {
    return switch (@typeInfo(T)) {
        .@"enum" => std.enums.values(T),
        else => &.{},
    };
}

pub fn defaultLabels(comptime T: type) []const []const u8 {
    return switch (@typeInfo(T)) {
        .@"enum" => enumTagNames(T, std.enums.values(T)),
        else => &.{},
    };
}

pub fn RadioButton(comptime T: type) type {
    return struct {
        selected: *T,
        value: T,
        key: Key,
        label: ?[]const u8 = null,
        onChange: ?*const fn (*App, T) anyerror!void = null,

        width: Element.sizing.Axis = .fit(),
        height: Element.sizing.Axis = .fit(),
        dot_size: f32 = 18,
        gap: f32 = 8,
        label_size: Size.Input = .sm,
        label_color: Color.Input = .text,
        unchecked_style: Style = .{ .color = .elevated, .border_color = .toned, .border_width = .all(1) },
        checked_style: Style = .{ .color = .elevated, .border_color = .primary, .border_width = .all(1) },
        dot_color: Color.Input = .primary,
        hover_border_color: Color.Input = .primary,

        const Self = @This();

        pub fn open(self: *const Self, app: *App) !Element.Id {
            const ui = &app.ui;

            const min_height = @max(self.dot_size, try ui.lineHeight(self.label_size.resolve(), null));
            const id = try ui.open(self.key, .{
                .width = self.width,
                .height = .{ .kind = self.height.kind, .value = self.height.value, .min = @max(self.height.min, min_height), .max = self.height.max },
                .direction = .row,
                .alignment = .center,
                .gap = self.gap,
                .interactive = true,
                .focusable = true,
            }, .none);
            try ui.setAccessibility(id, .{
                .role = .radio,
                .name = self.label orelse &.{},
                .state = .{ .checked = std.meta.eql(self.selected.*, self.value) },
            });

            const key_activate = ui.focused(id) and
                (ui.input.containsKey(.space) or ui.input.containsKey(.enter) or ui.input.containsKey(.kp_enter));
            const activate = ui.leftClickedWithin(id) or key_activate;
            if (activate) {
                if (!std.meta.eql(self.selected.*, self.value)) {
                    self.selected.* = self.value;
                    if (self.onChange) |cb| try cb(app, self.value);
                }
                if (key_activate) ui.input.consumeKeyboard();
            }

            return id;
        }

        pub fn close(self: *const Self, app: *App) !void {
            const ui = &app.ui;
            const id = self.key.hash();
            const selected = std.meta.eql(self.selected.*, self.value);
            const hovered = ui.hovering(id) or ui.isHoveredWithin(id);
            const focused = ui.focused(id);
            const t = ui.anim(id, "hover", if (hovered or focused) 1.0 else 0.0, .{ .duration_ms = 100 });

            const base_style = if (selected) self.checked_style else self.unchecked_style;
            var rect = base_style.toRect(&ui.theme);
            const hover_border = self.hover_border_color.resolve(&ui.theme);
            rect.border_color = .{
                rect.border_color[0] + (hover_border[0] - rect.border_color[0]) * t,
                rect.border_color[1] + (hover_border[1] - rect.border_color[1]) * t,
                rect.border_color[2] + (hover_border[2] - rect.border_color[2]) * t,
                rect.border_color[3] + (hover_border[3] - rect.border_color[3]) * t,
            };

            const cmds = try app.arena().alloc(Decoration.DrawCmd, 3);
            const center = self.dot_size * 0.5;
            const outer_radius = @max(0, self.dot_size * 0.5 - 1);
            const inner_radius = @max(0, self.dot_size * 0.27);
            cmds[0] = .{ .fill_circle = .{
                .cx = center,
                .cy = center,
                .radius = outer_radius,
                .color = rect.color,
            } };
            cmds[1] = .{ .stroke_circle = .{
                .cx = center,
                .cy = center,
                .radius = outer_radius,
                .color = rect.border_color,
                .thickness = @max(1, rect.border_width.max()),
            } };
            cmds[2] = .{ .fill_circle = .{
                .cx = center,
                .cy = center,
                .radius = inner_radius,
                .color = if (selected) self.dot_color.resolve(&ui.theme) else .{ 0, 0, 0, 0 },
            } };

            _ = try ui.open(self.key.indexed(1), .{
                .width = .fixed(self.dot_size),
                .height = .fixed(self.dot_size),
            }, .{ .canvas = .{ .cmds = cmds } });
            ui.close();

            if (self.label) |label| {
                try app.e(Text{
                    .content = label,
                    .size = self.label_size,
                    .color = self.label_color,
                    .selectable = false,
                    .key = self.key.indexed(2),
                });
            }

            ui.close();
        }
    };
}

pub fn RadioGroup(comptime T: type) type {
    const enum_values = defaultValues(T);
    const enum_labels = defaultLabels(T);

    return struct {
        selected: *T,
        key: Key,
        values: []const T = enum_values,
        labels: []const []const u8 = enum_labels,
        onChange: ?*const fn (*App, T) anyerror!void = null,

        width: Element.sizing.Axis = .fit(),
        height: Element.sizing.Axis = .fit(),
        padding: Element.Padding = .init(0, 0, 0, 0),
        dir: Element.Direction = .column,
        gap: f32 = 6,
        @"align": Element.Align = .start,
        justify: Element.Justify = .start,

        dot_size: f32 = 18,
        label_size: Size.Input = .sm,
        label_color: Color.Input = .text,
        unchecked_style: Style = .{ .color = .elevated, .border_color = .toned, .border_width = .all(1) },
        checked_style: Style = .{ .color = .elevated, .border_color = .primary, .border_width = .all(1) },
        dot_color: Color.Input = .primary,
        hover_border_color: Color.Input = .primary,

        const Self = @This();

        pub fn open(self: *const Self, app: *App) !Element.Id {
            if (self.values.len != self.labels.len) return error.RadioGroupMismatchedOptions;
            if (self.values.len > 0 and
                (app.ui.input.containsKey(.left) or app.ui.input.containsKey(.up) or
                    app.ui.input.containsKey(.right) or app.ui.input.containsKey(.down)))
            {
                var focused_index: ?usize = null;
                for (self.values, 0..) |_, i| {
                    if (app.ui.state.focused == self.key.indexed(1 + i).hash()) {
                        focused_index = i;
                        break;
                    }
                }
                if (focused_index) |i| {
                    const backward = app.ui.input.containsKey(.left) or app.ui.input.containsKey(.up);
                    const next_i = if (backward)
                        (i + self.values.len - 1) % self.values.len
                    else
                        (i + 1) % self.values.len;
                    const next = self.values[next_i];
                    if (!std.meta.eql(self.selected.*, next)) {
                        self.selected.* = next;
                        if (self.onChange) |cb| try cb(app, next);
                    }
                    app.ui.state.focused = self.key.indexed(1 + next_i).hash();
                    app.ui.input.consumeKeyboard();
                }
            }
            return try app.ui.open(self.key, .{
                .width = self.width,
                .height = self.height,
                .padding = self.padding,
                .direction = self.dir,
                .gap = self.gap,
                .alignment = self.@"align",
                .justify = self.justify,
            }, .none);
        }

        pub fn close(self: *const Self, app: *App) !void {
            for (self.values, self.labels, 0..) |value, label, i| {
                try app.e(RadioButton(T){
                    .selected = self.selected,
                    .value = value,
                    .key = self.key.indexed(1 + i),
                    .label = label,
                    .onChange = self.onChange,
                    .dot_size = self.dot_size,
                    .label_size = self.label_size,
                    .label_color = self.label_color,
                    .unchecked_style = self.unchecked_style,
                    .checked_style = self.checked_style,
                    .dot_color = self.dot_color,
                    .hover_border_color = self.hover_border_color,
                });
            }
            app.ui.close();
        }
    };
}
