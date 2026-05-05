const knots = @import("knots");
const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Spacer = knots.component.Spacer;

pub fn panel(
    app: *knots.App,
    comptime title: []const u8,
    comptime description: []const u8,
    body: *const fn (*knots.App) anyerror!void,
) !void {
    const wrap = Rect{
        .width = .grow(),
        .height = .grow(),
        .padding = .init(20, 20, 20, 20),
        .dir = .column,
        .overflow = .scroll_y,
        .key = .str("panel:" ++ title),
        .style = .{
            .color = .bg,
            .corner_radius = .lg,
            .border_width = 1,
            .border_color = .toned,
        },
    };
    _ = try wrap.open(app);
    try app.e(.{
        Text{
            .content = title,
            .size = .xl,
            .key = .str("panel.title:" ++ title),
        },
        Spacer{ .height = .fixed(4), .key = .str("panel.s1:" ++ title) },
        Text{
            .content = description,
            .color = .dimmed,
            .size = .sm,
            .key = .str("panel.desc:" ++ title),
        },
        Spacer{ .height = .fixed(16), .key = .str("panel.s2:" ++ title) },
    });
    try body(app);
    try wrap.close(app);
}
