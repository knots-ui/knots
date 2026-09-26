const std = @import("std");

const ui_mod = @import("../root.zig");

const UI = ui_mod.UI;
const Style = ui_mod.Style;
const Key = ui_mod.Key;
const Decoration = ui_mod.Decoration;

const Frame = @import("../root.zig").Frame;

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
        style: *const Style = &.{},
        parts: Parts = .{},

        pub const Parts = select_parts;
        pub const base = select_base;

        const Self = @This();

        pub const Selection = struct {
            value: T,
            index: u32,
        };

        pub const Response = struct {
            id: Element.Id,
            selected: ?Selection,
        };

        pub fn interact(self: *const Self, frame: *Frame) !Response {
            const id = self.key.hash();
            const previous = if (frame.ui().state.get(.select_input, id)) |state|
                state.selected
            else
                self.initial_selected;
            const element_id = try self.open(frame);
            try self.close(frame);
            const state = try frame.ui().state.getOrCreate(
                .select_input,
                frame.ui().allocator,
                id,
            );
            const selected = if (state.selected != previous)
                if (state.selected) |index|
                    Selection{ .value = self.values[index], .index = index }
                else
                    null
            else
                null;
            return .{ .id = element_id, .selected = selected };
        }

        pub fn open(self: *const Self, frame: *Frame) !Element.Id {
            if (self.labels.len != self.values.len) return error.SelectInputMismatchedOptions;
            if (!has_implicit_options and self.values.len == 0) return error.SelectInputRequiresOptions;
            const ui = frame.ui();

            const id = self.key.hash();
            const existed = ui.state.get(.select_input, id) != null;
            const s = try ui.state.getOrCreate(.select_input, ui.allocator, id);
            if (!existed) s.selected = self.initial_selected;

            if (ui.leftPressed(id, .exact)) s.open = !s.open;
            if (ui.consumeAccessibilityAction(id, .click) != null) s.open = !s.open;
            if (ui.consumeAccessibilityAction(id, .expand) != null) s.open = true;
            if (ui.consumeAccessibilityAction(id, .collapse) != null) s.open = false;
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
                    if (ui.leftPressed(opt_id, .exact) or ui.consumeAccessibilityAction(opt_id, .click) != null) {
                        const idx_u32: u32 = @intCast(i);
                        s.open = false;
                        s.selected = idx_u32;
                        break;
                    }
                }
            }

            if (s.open and ui.input.mouseButton(.left).pressed) {
                const popup_id = self.key.indexed(3).hash();
                if (ui.state.hovered != id and !ui.isHoveredWithin(popup_id)) s.open = false;
            }

            const root = ui.resolveStyle(id, .{ .base = &base.root, .user = self.style }, ui.states(id, .{ .open = s.open }), null);
            var config = root.element(.{ .interactive = true, .focusable = true });
            config.height.min = @max(config.height.min, try ui.lineHeight(root.content.font_size, root.content.font) + 12);
            const element_id = try ui.openResolved(self.key, &root, config, null);
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

        pub fn close(self: *const Self, frame: *Frame) !void {
            const ui = frame.ui();
            const id = self.key.hash();
            const s = try ui.state.getOrCreate(.select_input, ui.allocator, id);
            const content = ui.contents.items[ui.currentSlot()];
            const st: Style.States = .{ .open = s.open };

            const selected_label: ?[]const u8 = if (s.selected) |sel| if (sel < self.labels.len) self.labels[sel] else null else null;
            if (selected_label) |label| {
                var deco = try ui.textDecoration(label, content.font_size, content.font, false);
                deco.text.color = content.foreground;
                _ = try ui.open(self.key.indexed(1), .{ .width = .fit(), .height = .fit() }, deco);
                ui.close();
            } else {
                _ = try ui.styledText(self.key.indexed(1), self.placeholder, .{ .base = &base.placeholder, .user = self.parts.placeholder }, st);
            }

            {
                const icon = ui.resolveStyle(self.key.indexed(2).hash(), .{ .base = &base.icon, .user = self.parts.icon }, st, null);
                const icon_size: f32 = if (icon.layout.width.kind == .fixed) icon.layout.width.value else @max(10, icon.content.font_size * 0.55);
                const mid = icon_size * 0.5;
                const icon_color = icon.content.foreground;
                const cmds = try frame.arena().alloc(Decoration.DrawCmd, 2);

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

                _ = try ui.openWith(self.key.indexed(2), .{ .width = .fixed(icon_size), .height = .fixed(icon_size) }, .{ .canvas = .{ .cmds = cmds } }, .{ .content = icon.content });
                ui.close();
            }

            ui.close();

            if (s.open) {
                const anchor = s.anchor_box;
                const viewport = s.viewport_box;
                const popup_key = self.key.indexed(3);
                const popup = ui.resolveStyle(popup_key.hash(), .{ .base = &base.popup, .user = self.parts.popup }, .{}, &content);

                const line_h = try ui.lineHeight(content.font_size, content.font);
                const item_h = line_h + 12 + 2;
                const dropdown_h = item_h * @as(f32, @floatFromInt(self.labels.len)) + 4;

                const viewport_h = viewport.y() + viewport.h();
                const space_below = viewport_h - (anchor.y() + anchor.h());
                const space_above = anchor.y() - viewport.y();

                const open_above = dropdown_h > space_below and space_above > space_below;
                const max_h = if (open_above) space_above else space_below;
                const popup_y = if (open_above) anchor.y() - @min(dropdown_h, max_h) else anchor.y() + anchor.h();

                var config = popup.element(.{});
                config.width = .fixed(anchor.w());
                config.height = .{ .kind = .fit, .max = max_h };
                const list_id = try ui.openResolved(popup_key, &popup, config, .{ anchor.x(), popup_y });
                try ui.setAccessibility(list_id, .{ .role = .list_box, .parent = self.key.hash() });

                for (self.labels, 0..) |option, i| {
                    const opt_key = self.key.indexed(4 + i);
                    const opt_id = opt_key.hash();
                    const is_selected = if (s.selected) |sel| sel == i else false;

                    {
                        const option_styled = try ui.openStyled(opt_key, .{ .base = &base.option, .user = self.parts.option }, ui.states(opt_id, .{ .checked = is_selected }), .{ .interactive = true });
                        try ui.setAccessibility(option_styled.id, .{
                            .role = .list_box_option,
                            .name = option,
                            .state = .{ .selected = is_selected },
                        });

                        {
                            const opt_content = option_styled.resolved.content;
                            var opt_deco = try ui.textDecoration(option, opt_content.font_size, opt_content.font, false);
                            opt_deco.text.color = opt_content.foreground;
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

const select_parts = struct {
    placeholder: *const Style = &.{},
    /// The chevron; `foreground` colors it, a fixed `width` sizes it.
    icon: *const Style = &.{},
    popup: *const Style = &.{},
    option: *const Style = &.{},
};

const select_base = struct {
    pub const root: Style = .{
        .width = .grow(),
        .direction = .row,
        .@"align" = .center,
        .justify = .space_between,
        .padding = .init(6, 10, 6, 10),
        .background = .elevated,
        .border_width = .all(1),
        .border_color = .toned,
        .font_size = .md,
        .hover = &.{ .border_color = .dimmed },
        .focus = &.{ .border_color = .accent },
        .open = &.{ .border_color = .accent },
    };
    pub const placeholder: Style = .{ .foreground = .dimmed };
    pub const icon: Style = .{};
    pub const popup: Style = .{
        .direction = .column,
        .padding = .init(2, 0, 2, 0),
        .overflow = .scroll_y,
        .layer = .dropdown,
        .background = .elevated,
        .border_width = .all(1),
        .border_color = .toned,
    };
    pub const option: Style = .{
        .width = .grow(),
        .padding = .init(7, 10, 7, 10),
        .radius = .sm,
        .hover = &.{ .background = .muted },
        .checked = &.{ .background = .muted },
    };
};
