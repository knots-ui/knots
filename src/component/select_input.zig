const std = @import("std");

const State = @import("ui").State;
const Style = @import("ui").Style;
const Color = @import("ui").Color;
const Size = @import("ui").Size;
const Key = @import("ui").Key;
const Decoration = @import("ui").Decoration;

const App = @import("knots").App;

const Element = @import("layout").Element;

fn enumTagNames(comptime T: type, comptime values: []const T) [][]const u8 {
    comptime var names: [values.len][]const u8 = undefined;
    for (values, 0..) |v, i| {
        names[i] = @tagName(v);
    }
    const fixed: [values.len][]const u8 = names;
    return @constCast(&fixed);
}

/// If `T` is an enum type, the values and labels will default to an auto-resolver if not provided.
pub fn SelectInput(comptime T: type) type {
    const has_implicit_options = switch (@typeInfo(T)) {
        .@"enum" => true,
        else => false,
    };
    const default_values: []const T = if (has_implicit_options) std.enums.values(T) else &.{};
    const default_labels: []const []const u8 = if (has_implicit_options) enumTagNames(T, std.enums.values(T)) else &.{};
    return struct {
        labels: []const []const u8 = default_labels,
        values: []const T = default_values,
        initial_selected: ?u32 = null,
        key: Key,

        placeholder: []const u8 = "Select...",
        width: Element.sizing.Axis = .grow(),
        height: Element.sizing.Axis = .fit(),
        size: Size.Input = .md,
        font: ?[]const u8 = null,
        color: Color.Input = .text,
        placeholder_color: Color.Input = .dimmed,
        style: Style = .{ .color = .elevated, .border_color = .toned, .border_width = .all(1) },
        hover_style: ?Style.Override = .{ .border_color = .dimmed },
        focused_style: Style = .{ .color = .elevated, .border_color = .primary, .border_width = .all(1) },
        option_style: Style = .{ .color = .elevated, .border_color = .toned, .border_width = .all(1) },
        option_hover_color: Color.Input = .muted,
        dropdown_z_index: u8 = 1,
        onSelect: ?*const fn (*App, T, u32) anyerror!void = null,

        const Self = @This();

        pub fn open(self: *const Self, app: *App) !Element.Id {
            if (self.labels.len != self.values.len) return error.SelectInputMismatchedOptions;
            if (!has_implicit_options and self.values.len == 0) return error.SelectInputRequiresOptions;
            const ui = &app.ui;

            const id = self.key.hash();
            const existed = ui.state.get(.select_input, id) != null;
            const s = try ui.state.getOrCreate(.select_input, ui.allocator, id);
            if (!existed) s.selected = self.initial_selected;

            if (ui.leftClicked(id)) s.open = !s.open;
            if (ui.focused(id)) {
                var next_selected: ?usize = null;
                if (ui.input.containsKey(.escape)) {
                    s.open = false;
                    ui.input.consumeKeyboard();
                } else if (ui.input.containsKey(.space) or ui.input.containsKey(.enter) or ui.input.containsKey(.kp_enter)) {
                    s.open = !s.open;
                    ui.input.consumeKeyboard();
                } else if (self.values.len > 0 and (ui.input.containsKey(.down) or ui.input.containsKey(.up) or ui.input.containsKey(.home) or ui.input.containsKey(.end))) {
                    if (!s.open) {
                        s.open = true;
                    } else if (ui.input.containsKey(.home)) {
                        next_selected = 0;
                    } else if (ui.input.containsKey(.end)) {
                        next_selected = self.values.len - 1;
                    } else {
                        const cur: usize = if (s.selected) |sel|
                            @intCast(@min(sel, @as(u32, @intCast(self.values.len - 1))))
                        else if (ui.input.containsKey(.up))
                            self.values.len - 1
                        else
                            0;
                        next_selected = if (ui.input.containsKey(.up))
                            (cur + self.values.len - 1) % self.values.len
                        else
                            (cur + 1) % self.values.len;
                    }
                    if (next_selected) |i| {
                        const idx_u32: u32 = @intCast(i);
                        s.selected = idx_u32;
                        if (self.onSelect) |cb| try cb(app, self.values[i], idx_u32);
                    }
                    ui.input.consumeKeyboard();
                }
            }
            if (s.open and ui.acceptsInput(id) and ui.input.containsKey(.escape)) {
                s.open = false;
                ui.input.consumeKeyboard();
            }

            if (s.open) {
                for (self.labels, 0..) |_, i| {
                    const opt_id = self.key.indexed(4 + i).hash();
                    if (ui.leftClicked(opt_id)) {
                        const idx_u32: u32 = @intCast(i);
                        s.selected = idx_u32;
                        s.open = false;
                        if (self.onSelect) |cb| try cb(app, self.values[i], idx_u32);
                        break;
                    }
                }
            }

            if (s.open and ui.input.mouse_left_pressed) {
                const popup_id = self.key.indexed(3).hash();
                if (ui.state.hovered != id and !ui.isHoveredWithin(popup_id)) s.open = false;
            }

            const is_hovered = ui.hovering(id);
            const current_style = if (s.open)
                self.focused_style
            else if (is_hovered)
                if (self.hover_style) |hs| self.style.merge(hs) else self.style
            else
                self.style;

            var h = self.height;
            h.min = try ui.lineHeight(self.size.resolve(), self.font) + 12;

            const decoration: Decoration = if (current_style.hasDecoration())
                .{ .rect = current_style.toRect(&ui.theme) }
            else
                .none;

            const element_id = try ui.open(self.key, .{
                .width = self.width,
                .height = h,
                .direction = .row,
                .alignment = .center,
                .justify = .space_between,
                .padding = .init(6, 10, 6, 10),
                .interactive = true,
                .focusable = true,
            }, decoration);
            const accessibility_name = if (s.selected) |sel|
                if (sel < self.labels.len) self.labels[sel] else self.placeholder
            else
                self.placeholder;
            try ui.setAccessibility(element_id, .{
                .role = .select,
                .name = accessibility_name,
                .state = .{ .expanded = s.open },
            });
            return element_id;
        }

        pub fn close(self: *const Self, app: *App) !void {
            const ui = &app.ui;
            const id = self.key.hash();
            const s = try ui.state.getOrCreate(.select_input, ui.allocator, id);
            const size = self.size.resolve();

            const display_text, const text_color = if (s.selected) |sel|
                if (sel < self.labels.len)
                    .{ self.labels[sel], self.color.resolve(&ui.theme) }
                else
                    .{ self.placeholder, self.placeholder_color.resolve(&ui.theme) }
            else
                .{ self.placeholder, self.placeholder_color.resolve(&ui.theme) };

            {
                var deco = try ui.textDecoration(display_text, size, self.font, false);
                deco.text.color = text_color;
                _ = try ui.open(self.key.indexed(1), .{ .width = .fit(), .height = .fit() }, deco);
                ui.close();
            }

            {
                const icon_size: f32 = @max(10, size.value * 0.55);
                const mid = icon_size * 0.5;
                const icon_color = self.color.resolve(&ui.theme);
                const cmds = try app.arena().alloc(Decoration.DrawCmd, 2);

                if (s.open) {
                    cmds[0] = .{ .line = .{
                        .from = .{ icon_size * 0.2, icon_size * 0.62 },
                        .to = .{ mid, icon_size * 0.34 },
                        .color = icon_color,
                        .thickness = 1.75,
                    } };
                    cmds[1] = .{ .line = .{
                        .from = .{ mid, icon_size * 0.34 },
                        .to = .{ icon_size * 0.8, icon_size * 0.62 },
                        .color = icon_color,
                        .thickness = 1.75,
                    } };
                } else {
                    cmds[0] = .{ .line = .{
                        .from = .{ icon_size * 0.2, icon_size * 0.38 },
                        .to = .{ mid, icon_size * 0.66 },
                        .color = icon_color,
                        .thickness = 1.75,
                    } };
                    cmds[1] = .{ .line = .{
                        .from = .{ mid, icon_size * 0.66 },
                        .to = .{ icon_size * 0.8, icon_size * 0.38 },
                        .color = icon_color,
                        .thickness = 1.75,
                    } };
                }

                _ = try ui.open(self.key.indexed(2), .{ .width = .fixed(icon_size), .height = .fixed(icon_size) }, .{ .canvas = .{ .cmds = cmds } });
                ui.close();
            }

            ui.close();

            if (s.open) {
                const anchor = s.anchor_box;
                const viewport = s.viewport_box;

                const line_h = try ui.lineHeight(size, self.font);
                const item_h = line_h + 12 + 2;
                const dropdown_h = item_h * @as(f32, @floatFromInt(self.labels.len)) + 4;

                const viewport_h = viewport.y() + viewport.h();
                const space_below = viewport_h - (anchor.y() + anchor.h());
                const space_above = anchor.y() - viewport.y();

                const open_above = dropdown_h > space_below and space_above > space_below;
                const max_h = if (open_above) space_above else space_below;
                const popup_y = if (open_above) anchor.y() - @min(dropdown_h, max_h) else anchor.y() + anchor.h();

                _ = try ui.openRoot(self.key.indexed(3), anchor.x(), popup_y, .{
                    .direction = .column,
                    .width = .fixed(anchor.w()),
                    .height = .{ .kind = .fit, .max = max_h },
                    .overflow = .scroll_y,
                    .z_index = self.dropdown_z_index,
                    .padding = .init(2, 0, 2, 0),
                }, .{ .rect = self.option_style.toRect(&ui.theme) });

                for (self.labels, 0..) |option, i| {
                    const opt_key = self.key.indexed(4 + i);
                    const opt_id = opt_key.hash();
                    const is_hovered = ui.hovering(opt_id);
                    const is_selected = if (s.selected) |sel| sel == i else false;

                    const opt_bg: Decoration = if (is_hovered or is_selected)
                        .{ .rect = .{
                            .color = self.option_hover_color.resolve(&ui.theme),
                            .corner_radius = ui.theme.radius.scale(0.5),
                        } }
                    else
                        .none;

                    {
                        _ = try ui.open(opt_key, .{
                            .width = .grow(),
                            .padding = .init(7, 10, 7, 10),
                            .interactive = true,
                        }, opt_bg);

                        {
                            var opt_deco = try ui.textDecoration(option, size, self.font, false);
                            opt_deco.text.color = self.color.resolve(&ui.theme);
                            _ = try ui.open(self.key.indexed(4 + self.labels.len + i), .{ .width = .fit(), .height = .fit() }, opt_deco);
                            ui.close();
                        }

                        ui.close();
                    }
                }

                ui.close();
            }
        }
    };
}
