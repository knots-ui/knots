const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Spacer = ui.component.Spacer;
const ContextMenu = ui.component.ContextMenu;

const Menu = ContextMenu(ContextActions);
const Selection = struct { action: []const u8 = "none", target: []const u8 = "none" };

selection: Selection = .{},

pub fn render(self: *@This(), _: *knots.App, frame: *ui.Frame) !void {
    const arena = frame.arena();

    try frame.e(.{
        Text{
            .content = try std.fmt.allocPrint(
                arena,
                "last action: {s} on {s}",
                .{ self.selection.action, self.selection.target },
            ),
            .key = .src(@src()),
        },
        Spacer{ .style = &.{ .height = .fixed(12) }, .key = .src(@src()) },
    });

    const grid = Rect{
        .key = .src(@src()),
        .style = &.{
            .width = .grow(),
            .height = .grow(),
            .direction = .grid,
            .gap = 12,
            .padding = .all(8),
            .grid = .{
                .cols = &.{ .{ .fr = 1 }, .{ .fr = 1 } },
                .rows = &.{ .{ .fr = 1 }, .{ .fr = 1 } },
            },
        },
    };

    _ = try grid.open(frame);
    try card(frame, &self.selection, "top-left", "Top left target", "menu.tl", .{ .row = 0, .col = 0 });
    try card(frame, &self.selection, "top-right", "Top right target", "menu.tr", .{ .row = 0, .col = 1 });
    try card(frame, &self.selection, "bottom-left", "Bottom left target", "menu.bl", .{ .row = 1, .col = 0 });
    try card(frame, &self.selection, "bottom-right", "Bottom right target", "menu.br", .{ .row = 1, .col = 1 });
    try grid.close(frame);
}

fn card(
    frame: *ui.Frame,
    selection: *Selection,
    comptime target: []const u8,
    comptime title: []const u8,
    comptime key_prefix: []const u8,
    placement: Rect.GridPlacement,
) !void {
    return frame.e(.{
        Menu{
            .key = .str(key_prefix ++ ".wrap"),
            .menu = ContextActions{
                .selection = selection,
                .target = target,
                .inspect_key = .str(key_prefix ++ ".inspect"),
                .duplicate_key = .str(key_prefix ++ ".duplicate"),
                .archive_key = .str(key_prefix ++ ".archive"),
            },
            .style = &.{ .width = .grow(), .height = .grow(), .direction = .column, .grid_cell = placement },
            .parts = .{ .popup = &.{ .width = .fixed(168) } },
        },
        .{
            Rect{
                .key = .str(key_prefix ++ ".card"),
                .style = &.{
                    .width = .grow(),
                    .height = .grow(),
                    .padding = .all(14),
                    .direction = .column,
                    .justify = .space_between,
                    .background = .muted,
                    .radius = .md,
                    .border_width = .all(1),
                    .border_color = .toned,
                },
            },
            .{
                Text{ .content = title, .style = &.{ .font_size = .md }, .selectable = false, .key = .str(key_prefix ++ ".title") },
                Text{ .content = "Right-click inside this area.", .style = &.{ .font_size = .xs, .foreground = .dimmed }, .selectable = false, .key = .str(key_prefix ++ ".hint") },
            },
        },
    });
}

const ContextActions = struct {
    selection: *Selection,
    target: []const u8,
    inspect_key: ui.Key,
    duplicate_key: ui.Key,
    archive_key: ui.Key,

    pub fn render(self: *const ContextActions, frame: *ui.Frame) anyerror!void {
        try frame.e(.{
            ActionRow{ .selection = self.selection, .target = self.target, .action = "inspect", .label = "Inspect", .key = self.inspect_key },
            ActionRow{ .selection = self.selection, .target = self.target, .action = "duplicate", .label = "Duplicate", .key = self.duplicate_key },
            ActionRow{ .selection = self.selection, .target = self.target, .action = "archive", .label = "Archive", .key = self.archive_key },
        });
    }
};

const ActionRow = struct {
    selection: *Selection,
    target: []const u8,
    action: []const u8,
    label: []const u8,
    key: ui.Key,

    /// Custom components get the same vocabulary and state handling as built-in ones.
    const row_style: ui.Style = .{
        .width = .grow(),
        .height = .fixed(30),
        .padding = .xy(10, 0),
        .@"align" = .center,
        .radius = .sm,
        .font_size = .sm,
        .hover = &.{ .background = .muted },
    };

    pub fn open(self: *const ActionRow, frame: *ui.Frame) !u64 {
        const id = self.key.hash();
        _ = try frame.ui().openStyled(self.key, .{ .base = &row_style, .user = &.{} }, frame.ui().states(id, .{}), .{ .interactive = true });

        try frame.e(Text{
            .content = self.label,
            .selectable = false,
            .key = self.key.indexed(1),
        });

        return id;
    }

    pub fn close(self: *const ActionRow, frame: *ui.Frame) !void {
        const id = self.key.hash();
        frame.ui().close();

        if (frame.ui().leftClicked(id, .within)) {
            self.selection.* = .{ .action = self.action, .target = self.target };
            frame.requestRedraw();
        }
    }
};
