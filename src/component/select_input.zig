const std = @import("std");
const UI = @import("ui").UI;
const State = @import("ui").State;
const Style = @import("ui").Style;
const Theme = @import("ui").Theme;
const Color = @import("ui").Color;
const App = @import("knots").App;
const Key = UI.Key;

const Element = @import("layout").Element;
const Decoration = UI.Decoration;

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
    const default_values, const default_labels = switch (@typeInfo(T)) {
        .@"enum" => .{ std.enums.values(T), enumTagNames(T, std.enums.values(T)) },
        else => .{ undefined, undefined },
    };
    return struct {
        labels: []const []const u8 = default_labels,
        values: []const T = default_values,
        initial_selected: ?u32 = null,
        key: Key,

        placeholder: []const u8 = "Select...",
        width: Element.sizing.Axis = .grow(),
        height: Element.sizing.Axis = .fit(),
        size: f32 = 14,
        color: Color.Input = .text,
        placeholder_color: Color.Input = .dimmed,
        style: Style = .{ .color = .muted },
        focused_style: Style = .{ .color = .elevated, .border_color = .primary, .border_width = 1 },
        option_style: Style = .{ .color = .elevated },
        option_hover_color: Color.Input = .toned,
        onSelect: ?*const fn (*App, T, u32) anyerror!void = null,

        const Self = @This();

        pub fn open(self: *const Self, app: *App) !Element.Id {
            std.debug.assert(self.labels.len == self.values.len);
            const ui = &app.ui;

            const id = self.key.hash();
            const existed = ui.state.get(.select_input, id) != null;
            const s = try ui.state.getOrCreate(.select_input, ui.allocator, id);
            if (!existed) s.selected = self.initial_selected;

            if (ui.clicked(id)) s.open = !s.open;

            if (s.open) {
                for (self.labels, 0..) |_, i| {
                    const opt_id = self.key.indexed(4 + i).hash();
                    if (ui.clicked(opt_id)) {
                        const idx_u32: u32 = @intCast(i);
                        s.selected = idx_u32;
                        s.open = false;
                        if (self.onSelect) |cb| try cb(app, self.values[i], idx_u32);
                        break;
                    }
                }
            }

            if (s.open and ui.input.mouse_pressed) {
                const popup_id = self.key.indexed(3).hash();
                if (ui.state.hovered != id and !ui.isHoveredWithin(popup_id)) s.open = false;
            }

            const current_style = if (s.open) self.focused_style else self.style;

            var h = self.height;
            h.min = try ui.lineHeight(self.size, null);

            const decoration: Decoration = if (current_style.hasDecoration())
                .{ .rect = current_style.toRect() }
            else
                .none;

            return try ui.open(self.key, .{
                .width = self.width,
                .height = h,
                .direction = .row,
                .alignment = .center,
                .justify = .space_between,
                .padding = .init(4, 8, 4, 8),
                .interactive = true,
            }, decoration);
        }

        pub fn close(self: *const Self, app: *App) !void {
            const ui = &app.ui;
            const id = self.key.hash();
            const s = try ui.state.getOrCreate(.select_input, ui.allocator, id);

            const display_text, const text_color = if (s.selected) |sel|
                if (sel < self.labels.len)
                    .{ self.labels[sel], self.color.resolve() }
                else
                    .{ self.placeholder, self.placeholder_color.resolve() }
            else
                .{ self.placeholder, self.placeholder_color.resolve() };

            {
                var deco = try ui.textDecoration(display_text, self.size, null);
                deco.text.color = text_color;
                _ = try ui.open(self.key.indexed(1), .{ .width = .fit(), .height = .fit() }, deco);
                ui.close();
            }

            {
                const arrow_str: []const u8 = if (s.open) "O" else ">";
                var arrow_deco = try ui.textDecoration(arrow_str, self.size * 0.8, null);
                arrow_deco.text.color = self.color.resolve();
                _ = try ui.open(self.key.indexed(2), .{ .width = .fit(), .height = .fit() }, arrow_deco);
                ui.close();
            }

            ui.close();

            if (s.open) {
                const anchor = s.anchor_box;
                const viewport = s.viewport_box;

                const line_h = try ui.lineHeight(self.size, null);
                const item_h = line_h + 12 + 2;
                const dropdown_h = item_h * @as(f32, @floatFromInt(self.labels.len)) + 4;

                const viewport_h = viewport.y + viewport.h;
                const space_below = viewport_h - (anchor.y + anchor.h);
                const space_above = anchor.y - viewport.y;

                const open_above = dropdown_h > space_below and space_above > space_below;
                const max_h = if (open_above) space_above else space_below;
                const popup_y = if (open_above) anchor.y - @min(dropdown_h, max_h) else anchor.y + anchor.h;

                _ = try ui.openRoot(self.key.indexed(3), anchor.x, popup_y, .{
                    .direction = .column,
                    .width = .fixed(anchor.w),
                    .height = .{ .kind = .fit, .max = max_h },
                    .overflow = .scroll_y,
                    .z_index = 1,
                    .padding = .init(2, 0, 2, 0),
                }, .{ .rect = self.option_style.toRect() });

                for (self.labels, 0..) |option, i| {
                    const opt_key = self.key.indexed(4 + i);
                    const opt_id = opt_key.hash();
                    const is_hovered = ui.hovering(opt_id);
                    const is_selected = if (s.selected) |sel| sel == i else false;

                    const opt_bg: Decoration = if (is_hovered or is_selected)
                        .{ .rect = .{ .color = self.option_hover_color.resolve() } }
                    else
                        .none;

                    {
                        _ = try ui.open(opt_key, .{
                            .width = .grow(),
                            .height = .fit(),
                            .padding = .init(6, 8, 6, 8),
                            .interactive = true,
                        }, opt_bg);

                        {
                            var opt_deco = try ui.textDecoration(option, self.size, null);
                            opt_deco.text.color = self.color.resolve();
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
