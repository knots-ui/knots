const knots = @import("knots");
const ui = @import("knots-ui");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const TextArea = ui.component.TextArea;
const Spacer = ui.component.Spacer;

const lorem =
    "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. " ++
    "How vexingly quick daft zebras jump! Sphinx of black quartz, judge my vow. " ++
    "Two driven jocks help fax my big quiz.";

const with_newlines =
    "First line is short.\n" ++
    "Second line is a bit longer and may still fit, depending on width.\n" ++
    "\n" ++
    "Empty line above. The greedy wrapper breaks on spaces and hard newlines, " ++
    "and falls back to mid-word breaks for runs longer than the wrap width.";

pub fn render(desktop: *knots.App, app: *ui.Frame) !void {
    try ui_helpers.panel(desktop, app, "Text wrap", body);
}

fn body(desktop: *knots.App, app: *ui.Frame) !void {
    const self = Self.of(desktop);
    const root = Rect{ .width = .grow(), .dir = .column, .gap = 16, .key = .src(@src()) };
    _ = try root.open(app);
    try fixedWidthSection(app);
    try growWidthSection(app);
    try newlinesSection(app);
    try multiLineInputSection(self, app);
    try root.close(app);
}

fn caption(app: *ui.Frame, comptime label: []const u8, key: ui.Key) !void {
    try app.e(Text{
        .content = label,
        .size = .xs,
        .color = .dimmed,
        .key = key,
    });
}

fn fixedWidthSection(app: *ui.Frame) !void {
    try caption(app, "fixed(220) container, text wraps inside a narrow column", .src(@src()));
    try app.e(.{
        Rect{
            .width = .fixed(220),
            .padding = .init(10, 10, 10, 10),
            .style = .{ .color = .muted, .corner_radius = .sm },
            .key = .src(@src()),
        },
        .{Text{
            .content = lorem,
            .wrap = true,
            .width = .grow(),
            .key = .src(@src()),
        }},
    });
}

fn growWidthSection(app: *ui.Frame) !void {
    try caption(app, "grow() in a row, text reflows when the window resizes", .src(@src()));
    try app.e(.{
        Rect{ .width = .grow(), .gap = 12, .key = .src(@src()) },
        .{
            Rect{
                .width = .grow(),
                .padding = .init(10, 10, 10, 10),
                .style = .{ .color = .muted, .corner_radius = .sm },
                .key = .src(@src()),
            },
            Rect{
                .width = .fixed(120),
                .padding = .init(10, 10, 10, 10),
                .style = .{ .color = .accented, .corner_radius = .sm },
                .key = .src(@src()),
            },
        },
    });

    try app.e(.{
        Rect{ .width = .grow(), .gap = 12, .key = .src(@src()) },
        .{
            growParagraph,
            Rect{
                .width = .fixed(120),
                .height = .fixed(60),
                .style = .{ .color = .accented, .corner_radius = .sm },
                .key = .src(@src()),
            },
        },
    });
}

fn growParagraph(app: *ui.Frame) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .padding = .init(10, 10, 10, 10),
            .style = .{ .color = .muted, .corner_radius = .sm },
            .key = .src(@src()),
        },
        .{Text{
            .content = lorem,
            .wrap = true,
            .width = .grow(),
            .key = .src(@src()),
        }},
    });
}

fn newlinesSection(app: *ui.Frame) !void {
    try caption(app, "hard \\n breaks combined with soft wrap", .src(@src()));
    try app.e(.{
        Rect{
            .width = .fixed(320),
            .padding = .init(10, 10, 10, 10),
            .style = .{ .color = .muted, .corner_radius = .sm },
            .key = .src(@src()),
        },
        .{Text{
            .content = with_newlines,
            .wrap = true,
            .width = .grow(),
            .key = .src(@src()),
        }},
    });
}

fn multiLineInputSection(self: *Self, app: *ui.Frame) !void {
    try caption(app, "TextArea: multi-line, enter inserts a newline, arrow up/down navigate lines; drag the bottom edge to resize height (persists)", .src(@src()));
    try app.e(TextArea{
        .key = .src(@src()),
        .buf = &self.demo_state.notes_buf,
        .placeholder = "type a multi-line note... drag the bottom edge to grow it",
        .width = .fixed(360),
        .height = .fixed(96),
    });
}
