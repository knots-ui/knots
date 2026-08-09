const knots = @import("knots");
const Rect = knots.component.Rect;

pub fn panel(
    desktop: *knots.App,
    frame: *knots.Frame,
    comptime title: []const u8,
    body: *const fn (*knots.App, *knots.Frame) anyerror!void,
) !void {
    const wrap = Rect{
        .width = .grow(),
        .height = .grow(),
        .padding = .init(16, 16, 16, 16),
        .dir = .column,
        .overflow = .scroll,
        .key = .str("panel:" ++ title),
        .style = .{
            .color = .elevated,
            .corner_radius = .lg,
            .border_width = .all(1),
            .border_color = .toned,
        },
    };
    _ = try wrap.open(frame);
    try body(desktop, frame);
    try wrap.close(frame);
}
