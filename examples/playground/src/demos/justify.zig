const knots = @import("knots");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Spacer = knots.component.Spacer;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(
        app,
        "Justify",
        "Main-axis distribution of three boxes inside a 360px-wide row.",
        body,
    );
}

fn body(app: *knots.App) !void {
    try rowStart(app);
    try rowCenter(app);
    try rowEnd(app);
    try rowSpaceBetween(app);
    try rowSpaceAround(app);
}

fn rowStart(app: *knots.App) !void {
    try app.e(Text{ .content = "start", .size = .xs, .color = .dimmed, .key = .src(@src()) });
    try app.e(Spacer{ .height = .fixed(2), .key = .src(@src()) });
    try app.e(.{
        Rect{ .width = .fixed(360), .height = .fixed(36), .padding = .init(4, 4, 4, 4), .dir = .row, .gap = 6, .justify = .start, .key = .src(@src()), .style = .{ .color = .muted, .corner_radius = .sm } },
        .{ box(.@"error", .src(@src())), box(.@"error", .src(@src())), box(.@"error", .src(@src())) },
    });
    try app.e(Spacer{ .height = .fixed(8), .key = .src(@src()) });
}

fn rowCenter(app: *knots.App) !void {
    try app.e(Text{ .content = "center", .size = .xs, .color = .dimmed, .key = .src(@src()) });
    try app.e(Spacer{ .height = .fixed(2), .key = .src(@src()) });
    try app.e(.{
        Rect{ .width = .fixed(360), .height = .fixed(36), .padding = .init(4, 4, 4, 4), .dir = .row, .gap = 6, .justify = .center, .key = .src(@src()), .style = .{ .color = .muted, .corner_radius = .sm } },
        .{ box(.success, .src(@src())), box(.success, .src(@src())), box(.success, .src(@src())) },
    });
    try app.e(Spacer{ .height = .fixed(8), .key = .src(@src()) });
}

fn rowEnd(app: *knots.App) !void {
    try app.e(Text{ .content = "end", .size = .xs, .color = .dimmed, .key = .src(@src()) });
    try app.e(Spacer{ .height = .fixed(2), .key = .src(@src()) });
    try app.e(.{
        Rect{ .width = .fixed(360), .height = .fixed(36), .padding = .init(4, 4, 4, 4), .dir = .row, .gap = 6, .justify = .end, .key = .src(@src()), .style = .{ .color = .muted, .corner_radius = .sm } },
        .{ box(.primary, .src(@src())), box(.primary, .src(@src())), box(.primary, .src(@src())) },
    });
    try app.e(Spacer{ .height = .fixed(8), .key = .src(@src()) });
}

fn rowSpaceBetween(app: *knots.App) !void {
    try app.e(Text{ .content = "space_between", .size = .xs, .color = .dimmed, .key = .src(@src()) });
    try app.e(Spacer{ .height = .fixed(2), .key = .src(@src()) });
    try app.e(.{
        Rect{ .width = .fixed(360), .height = .fixed(36), .padding = .init(4, 4, 4, 4), .dir = .row, .justify = .space_between, .key = .src(@src()), .style = .{ .color = .muted, .corner_radius = .sm } },
        .{ box(.info, .src(@src())), box(.info, .src(@src())), box(.info, .src(@src())) },
    });
    try app.e(Spacer{ .height = .fixed(8), .key = .src(@src()) });
}

fn rowSpaceAround(app: *knots.App) !void {
    try app.e(Text{ .content = "space_around", .size = .xs, .color = .dimmed, .key = .src(@src()) });
    try app.e(Spacer{ .height = .fixed(2), .key = .src(@src()) });
    try app.e(.{
        Rect{ .width = .fixed(360), .height = .fixed(36), .padding = .init(4, 4, 4, 4), .dir = .row, .justify = .space_around, .key = .src(@src()), .style = .{ .color = .muted, .corner_radius = .sm } },
        .{ box(.warning, .src(@src())), box(.warning, .src(@src())), box(.warning, .src(@src())) },
    });
}

fn box(comptime color: knots.ui.Color.Input, key: knots.ui.Key) Rect {
    return .{
        .width = .fixed(28),
        .height = .fixed(28),
        .style = .{ .color = color, .corner_radius = .sm },
        .key = key,
    };
}
