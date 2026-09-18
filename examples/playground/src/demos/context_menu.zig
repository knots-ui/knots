const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Spacer = ui.component.Spacer;
const ContextMenu = ui.component.ContextMenu;

const Menu = ContextMenu(ContextActions);
var last_action: []const u8 = "none";
var last_target: []const u8 = "none";

pub fn main(app: *knots.Frame) !void {
    const arena = app.arena();

    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(
                arena,
                "last action: {s} on {s}",
                .{ last_action, last_target },
            ),
            .key = .src(@src()),
        },
        Spacer{ .height = .fixed(12), .key = .src(@src()) },
    });

    const grid = Rect{
        .width = .grow(),
        .height = .grow(),
        .dir = .grid,
        .gap = 12,
        .padding = .init(8, 8, 8, 8),
        .grid_template = .{
            .cols = &.{ .{ .fr = 1 }, .{ .fr = 1 } },
            .rows = &.{ .{ .fr = 1 }, .{ .fr = 1 } },
        },
        .key = .src(@src()),
    };

    _ = try grid.open(app);
    try card(app, "top-left", "Top left target", "menu.tl", .{ .row = 0, .col = 0 });
    try card(app, "top-right", "Top right target", "menu.tr", .{ .row = 0, .col = 1 });
    try card(app, "bottom-left", "Bottom left target", "menu.bl", .{ .row = 1, .col = 0 });
    try card(app, "bottom-right", "Bottom right target", "menu.br", .{ .row = 1, .col = 1 });
    try grid.close(app);
}

fn card(
    app: *ui.Frame,
    comptime target: []const u8,
    comptime title: []const u8,
    comptime key_prefix: []const u8,
    placement: Rect.GridPlacement,
) !void {
    return app.e(.{
        Menu{
            .key = .str(key_prefix ++ ".wrap"),
            .menu = ContextActions{
                .target = target,
                .inspect_key = .str(key_prefix ++ ".inspect"),
                .duplicate_key = .str(key_prefix ++ ".duplicate"),
                .archive_key = .str(key_prefix ++ ".archive"),
            },
            .width = .grow(),
            .height = .grow(),
            .dir = .column,
            .grid_placement = placement,
            .menu_width = 168,
        },
        .{
            Rect{
                .width = .grow(),
                .height = .grow(),
                .padding = .init(14, 14, 14, 14),
                .dir = .column,
                .justify = .space_between,
                .key = .str(key_prefix ++ ".card"),
                .style = .{
                    .color = .muted,
                    .corner_radius = .md,
                    .border_width = .all(1),
                    .border_color = .toned,
                },
            },
            .{
                Text{ .content = title, .size = .md, .selectable = false, .key = .str(key_prefix ++ ".title") },
                Text{ .content = "Right-click inside this area.", .size = .xs, .color = .dimmed, .selectable = false, .key = .str(key_prefix ++ ".hint") },
            },
        },
    });
}

const ContextActions = struct {
    target: []const u8,
    inspect_key: ui.Key,
    duplicate_key: ui.Key,
    archive_key: ui.Key,

    pub fn render(self: *const ContextActions, app: *ui.Frame) anyerror!void {
        try app.e(.{
            ActionRow{ .target = self.target, .action = "inspect", .label = "Inspect", .key = self.inspect_key },
            ActionRow{ .target = self.target, .action = "duplicate", .label = "Duplicate", .key = self.duplicate_key },
            ActionRow{ .target = self.target, .action = "archive", .label = "Archive", .key = self.archive_key },
        });
    }
};

const ActionRow = struct {
    target: []const u8,
    action: []const u8,
    label: []const u8,
    key: ui.Key,

    pub fn open(self: *const ActionRow, app: *ui.Frame) !u64 {
        const id = self.key.hash();
        const hovered = app.ui().hovering(id);

        _ = try app.ui().open(self.key, .{
            .width = .grow(),
            .height = .fixed(30),
            .padding = .init(0, 10, 0, 10),
            .alignment = .center,
            .interactive = true,
        }, .{ .rect = .{
            .color = (if (hovered) app.ui().theme.muted else app.ui().theme.elevated).value,
            .corner_radius = app.ui().theme.radius.scale(0.5),
        } });

        try app.e(Text{
            .content = self.label,
            .size = .sm,
            .selectable = false,
            .key = self.key.indexed(1),
        });

        return id;
    }

    pub fn close(self: *const ActionRow, app: *ui.Frame) !void {
        const id = self.key.hash();
        app.ui().close();

        if (app.ui().leftClicked(id, .within)) {
            last_action = self.action;
            last_target = self.target;
            app.requestRedraw();
        }
    }
};
