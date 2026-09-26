const std = @import("std");

const Frame = @import("../root.zig").Frame;
const Element = @import("layout").Element;
const ui_mod = @import("../root.zig");

const Decoration = ui_mod.Decoration;
const Key = ui_mod.Key;
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

const radio_parts = struct {
    box: *const Style = &.{},
    /// `foreground` colors the dot.
    indicator: *const Style = &.{},
    label: *const Style = &.{},
};

const radio_base = struct {
    pub const root: Style = .{ .direction = .row, .@"align" = .center, .gap = 8 };
    pub const box: Style = .{
        .width = .fixed(18),
        .height = .fixed(18),
        .background = .elevated,
        .radius = .{ .fixed = 9 },
        .border_width = .all(1),
        .border_color = .toned,
        .hover = &.{ .border_color = .accent },
        .focus = &.{ .border_color = .accent },
        .checked = &.{ .border_color = .accent },
        .transition = .{ .duration_ms = 100 },
    };
    pub const indicator: Style = .{ .width = .grow(), .height = .grow(), .foreground = .accent };
    pub const label: Style = .{};
};

const BOX_INDEX: usize = 1;
const LABEL_INDEX: usize = 2;
const INDICATOR_INDEX: usize = 3;

pub fn RadioButton(comptime T: type) type {
    return struct {
        selected: *T,
        value: T,
        label: ?[]const u8 = null,
        key: Key,
        style: *const Style = &.{},
        parts: Parts = .{},

        pub const Parts = radio_parts;
        pub const base = radio_base;

        const Self = @This();

        pub const Response = struct {
            id: Element.Id,
            changed: bool,
        };

        pub fn interact(self: *const Self, frame: *Frame) !Response {
            const previous = self.selected.*;
            const id = try self.open(frame);
            try self.close(frame);
            return .{
                .id = id,
                .changed = !std.meta.eql(previous, self.selected.*),
            };
        }

        pub fn open(self: *const Self, frame: *Frame) !Element.Id {
            const ui = frame.ui();
            const id = self.key.hash();

            const key_activate = ui.focused(id) and
                (ui.input.containsKey(.space) or ui.input.containsKey(.enter) or ui.input.containsKey(.kp_enter));
            const activate = ui.leftClicked(id, .within) or key_activate or ui.consumeAccessibilityAction(id, .click) != null;
            if (activate) {
                if (!std.meta.eql(self.selected.*, self.value)) {
                    self.selected.* = self.value;
                }
                if (key_activate) ui.input.consumeKeyboard();
            }

            const selected = std.meta.eql(self.selected.*, self.value);
            const st = ui.states(id, .{ .checked = selected });
            const root = ui.resolveStyle(id, .{ .base = &radio_base.root, .user = self.style }, st, null);
            const box = ui.resolveStyle(self.key.indexed(BOX_INDEX).hash(), .{ .base = &radio_base.box, .user = self.parts.box }, st, null);
            var config = root.element(.{ .interactive = true, .focusable = true });
            const box_h = if (box.layout.height.kind == .fixed) box.layout.height.value else 0;
            config.height.min = @max(config.height.min, @max(box_h, try ui.lineHeight(root.content.font_size, root.content.font)));
            _ = try ui.openResolved(self.key, &root, config, null);
            try ui.setAccessibility(id, .{
                .role = .radio,
                .name = self.label orelse &.{},
                .state = .{ .checked = selected },
            });
            return id;
        }

        pub fn close(self: *const Self, frame: *Frame) !void {
            const ui = frame.ui();
            const id = self.key.hash();
            const selected = std.meta.eql(self.selected.*, self.value);
            const st = ui.states(id, .{ .checked = selected });

            const box = try ui.openStyled(self.key.indexed(BOX_INDEX), .{ .base = &radio_base.box, .user = self.parts.box }, st, .{});
            {
                const indicator = ui.resolveStyle(self.key.indexed(INDICATOR_INDEX).hash(), .{ .base = &radio_base.indicator, .user = self.parts.indicator }, st, null);
                const size = if (box.resolved.layout.width.kind == .fixed) box.resolved.layout.width.value else 18;
                const cmds: []const Decoration.DrawCmd = if (selected) try frame.arena().dupe(Decoration.DrawCmd, &[_]Decoration.DrawCmd{
                    .{ .fill_circle = .{ .cx = size * 0.5, .cy = size * 0.5, .radius = @max(0, size * 0.27), .color = indicator.content.foreground } },
                }) else &.{};
                _ = try ui.openWith(self.key.indexed(INDICATOR_INDEX), indicator.element(.{}), .{ .canvas = .{ .cmds = cmds } }, .{ .content = indicator.content });
                ui.close();
            }
            ui.close();

            if (self.label) |label| {
                _ = try ui.styledText(self.key.indexed(LABEL_INDEX), label, .{ .base = &radio_base.label, .user = self.parts.label }, st);
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
        style: *const Style = &.{},
        parts: GroupParts = .{},

        pub const Parts = GroupParts;
        pub const base = struct {
            pub const root: Style = .{ .direction = .column, .gap = 6 };
            pub const option = radio_base.root;
            pub const box = radio_base.box;
            pub const indicator = radio_base.indicator;
            pub const label = radio_base.label;
        };

        const Self = @This();

        pub const Response = struct {
            id: Element.Id,
            changed: bool,
        };

        pub fn interact(self: *const Self, frame: *Frame) !Response {
            const previous = self.selected.*;
            const id = try self.open(frame);
            try self.close(frame);
            return .{
                .id = id,
                .changed = !std.meta.eql(previous, self.selected.*),
            };
        }

        pub fn open(self: *const Self, frame: *Frame) !Element.Id {
            if (self.values.len != self.labels.len) return error.RadioGroupMismatchedOptions;
            if (self.values.len > 0 and
                (frame.ui().input.containsKey(.left) or frame.ui().input.containsKey(.up) or
                    frame.ui().input.containsKey(.right) or frame.ui().input.containsKey(.down)))
            {
                var focused_index: ?usize = null;
                for (self.values, 0..) |_, i| {
                    if (frame.ui().state.focused == self.key.indexed(1 + i).hash()) {
                        focused_index = i;
                        break;
                    }
                }
                if (focused_index) |i| {
                    const backward = frame.ui().input.containsKey(.left) or frame.ui().input.containsKey(.up);
                    const next_i = if (backward)
                        (i + self.values.len - 1) % self.values.len
                    else
                        (i + 1) % self.values.len;
                    const next = self.values[next_i];
                    if (!std.meta.eql(self.selected.*, next)) {
                        self.selected.* = next;
                    }
                    frame.ui().state.focused = self.key.indexed(1 + next_i).hash();
                    frame.ui().input.consumeKeyboard();
                }
            }
            return (try frame.ui().openStyled(self.key, .{ .base = &base.root, .user = self.style }, .{}, .{})).id;
        }

        pub fn close(self: *const Self, frame: *Frame) !void {
            for (self.values, self.labels, 0..) |value, label, i| {
                try frame.e(RadioButton(T){
                    .selected = self.selected,
                    .value = value,
                    .key = self.key.indexed(1 + i),
                    .label = label,
                    .style = self.parts.option,
                    .parts = .{ .box = self.parts.box, .indicator = self.parts.indicator, .label = self.parts.label },
                });
            }
            frame.ui().close();
        }
    };
}

const GroupParts = struct {
    /// Each option's root style.
    option: *const Style = &.{},
    box: *const Style = &.{},
    indicator: *const Style = &.{},
    label: *const Style = &.{},
};
