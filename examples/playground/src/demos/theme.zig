const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Theme = ui.Theme;

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Spacer = ui.component.Spacer;

const Entry = struct {
    name: []const u8,
    theme: Theme,
};

const entries = blk: {
    @setEvalBranchQuota(50000);
    break :blk [_]Entry{
        .{ .name = "dark", .theme = Theme.dark },
        .{ .name = "light", .theme = Theme.light },
        .{ .name = "forest night", .theme = Theme.parse(@import("../themes/forest_night.zon")) },
        .{ .name = "graphite neon", .theme = Theme.parse(@import("../themes/graphite_neon.zon")) },
        .{ .name = "gruvbox", .theme = Theme.parse(@import("../themes/gruvbox.zon")) },
        .{ .name = "midnight ocean", .theme = Theme.parse(@import("../themes/midnight_ocean.zon")) },
        .{ .name = "monochrome ash", .theme = Theme.parse(@import("../themes/monochrome_ash.zon")) },
        .{ .name = "nord frost", .theme = Theme.parse(@import("../themes/nord_frost.zon")) },
        .{ .name = "rose mist", .theme = Theme.parse(@import("../themes/rose_mist.zon")) },
        .{ .name = "warm sand", .theme = Theme.parse(@import("../themes/warm_sand.zon")) },
    };
};

pub fn main(app: *knots.Frame) !void {
    const theme_index = try app.bindState(u32, "playground.theme.index", 1);
    const root = Rect{
        .width = .grow(),
        .height = .fixed(800),
        .dir = .column,
        .gap = 12,
        .key = .src(@src()),
    };
    _ = try root.open(app);
    inline for (0..entries.len) |index| {
        try Slot(index).render(app, theme_index);
    }
    try root.close(app);
}

fn Slot(comptime idx: u32) type {
    return struct {
        pub fn render(app: *ui.Frame, theme_index: *u32) !void {
            const entry = entries[idx];
            const is_active = theme_index.* == idx;

            const cell = Rect{
                .width = .grow(),
                .height = .grow(),
                .key = .str("theme.cell:" ++ entry.name),
                .dir = .column,
            };
            _ = try cell.open(app);
            const button = Button{
                .width = .grow(),
                .height = .grow(),
                .padding = .init(12, 12, 12, 12),
                .key = .str("theme.swatch:" ++ entry.name),
                .style = .{
                    .color = .{ .color = entry.theme.elevated },
                    .corner_radius = .md,
                    .border_width = if (is_active) .all(2) else .all(1),
                    .border_color = if (is_active)
                        .{ .color = entry.theme.primary }
                    else
                        .{ .color = entry.theme.toned },
                },
                .hover_anim = .{},
            };
            const response = try button.openResponse(app);
            try app.e(.{
                Rect{
                    .@"align" = .center,
                    .justify = .space_between,
                    .key = .str("theme.button.container:" ++ entry.name),
                    .dir = .column,
                },
                .{
                    Text{
                        .content = entry.name,
                        .size = .md,
                        .color = .{ .color = entry.theme.text },
                        .selectable = false,
                        .key = .str("theme.label:" ++ entry.name),
                    },
                    Rect{
                        .width = .grow(),
                        .height = .fixed(20),
                        .dir = .row,
                        .gap = 4,
                        .key = .str("theme.row:" ++ entry.name),
                    },
                    .{
                        chip(entry.theme.primary, "p", entry.name),
                        chip(entry.theme.secondary, "s", entry.name),
                        chip(entry.theme.success, "ok", entry.name),
                        chip(entry.theme.warning, "wa", entry.name),
                        chip(entry.theme.@"error", "er", entry.name),
                        chip(entry.theme.muted, "mu", entry.name),
                    },
                },
            });
            try button.close(app);
            try cell.close(app);
            if (response.clicked) {
                theme_index.* = idx;
                app.ui().theme = entries[idx].theme;
                app.requestRedraw();
            }
        }
    };
}

fn chip(color: ui.Color, comptime tag: []const u8, comptime theme_name: []const u8) Rect {
    return Rect{
        .width = .fixed(20),
        .height = .fixed(20),
        .key = .str("theme.chip:" ++ theme_name ++ ":" ++ tag),
        .style = .{
            .color = .{ .color = color },
            .corner_radius = .sm,
        },
    };
}
