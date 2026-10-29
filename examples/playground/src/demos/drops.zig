const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Spacer = ui.component.Spacer;
const For = ui.control.For;

paths: std.ArrayList([]const u8) = .empty,

pub fn render(self: *@This(), app: *knots.App, frame: *ui.Frame) !void {
    const arena = frame.arena();

    const new_paths = frame.droppedPaths();
    if (new_paths.len > 0) {
        for (new_paths) |path| {
            const copy = try app.allocator.dupe(u8, path);
            errdefer app.allocator.free(copy);
            try self.paths.append(app.allocator, copy);
        }
        frame.requestRedraw();
    }

    const row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .gap = 8, .@"align" = .center } };
    _ = try row.open(frame);
    if ((try frame.interact(Button{
        .key = .src(@src()),
        .label = "clear",
        .style = &.{ .height = .fixed(28), .width = .fixed(80), .tone = .@"error" },
    })).clicked) {
        self.clear(app.allocator);
        frame.requestRedraw();
    }
    try frame.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "{d} paths", .{self.paths.items.len}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed },
        },
    });
    try row.close(frame);

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(12) } });

    if (self.paths.items.len == 0) {
        try frame.e(Text{
            .content = "no drops yet - try dragging a file onto the window.",
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed },
        });
        return;
    }

    try frame.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .padding = .init(8, 8, 8, 8), .background = .muted, .radius = .sm, .border_width = .all(1), .border_color = .toned, .direction = .column, .gap = 4 },
        },
        .{
            For([]const u8){
                .items = self.paths.items,
                .each = renderItem,
            },
        },
    });
}

fn renderItem(frame: *ui.Frame, path: []const u8, i: usize) !void {
    try frame.e(.{
        Rect{
            .key = ui.Key.src(@src()).indexed(i),
            .style = &.{ .width = .grow(), .height = .fixed(24), .padding = .init(0, 8, 0, 8), .@"align" = .center, .background = .elevated, .radius = .sm },
        },
        .{Text{
            .content = path,
            .key = ui.Key.src(@src()).indexed(i),
            .style = &.{ .font_size = .sm },
        }},
    });
}

fn clear(self: *@This(), allocator: std.mem.Allocator) void {
    for (self.paths.items) |path| allocator.free(path);
    self.paths.clearRetainingCapacity();
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.clear(allocator);
    self.paths.deinit(allocator);
}
