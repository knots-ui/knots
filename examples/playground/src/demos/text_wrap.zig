const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

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
var notes: std.ArrayList(u8) = .empty;
var allocator: ?std.mem.Allocator = null;

pub fn render(_: *knots.App, app: *ui.Frame) !void {
    allocator = app.ui().allocator;
    const root = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .column, .gap = 16 } };
    _ = try root.open(app);
    try fixedWidthSection(app);
    try growWidthSection(app);
    try newlinesSection(app);
    try multiLineInputSection(app);
    try root.close(app);
}

fn caption(app: *ui.Frame, comptime label: []const u8, key: ui.Key) !void {
    try app.e(Text{
        .content = label,
        .key = key,
        .style = &.{ .font_size = .xs, .foreground = .dimmed },
    });
}

fn fixedWidthSection(app: *ui.Frame) !void {
    try caption(app, "fixed(220) container, text wraps inside a narrow column", .src(@src()));
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .fixed(220), .padding = .init(10, 10, 10, 10), .background = .muted, .radius = .sm },
        },
        .{Text{
            .content = lorem,
            .key = .src(@src()),
            .style = &.{ .wrap = true, .width = .grow() },
        }},
    });
}

fn growWidthSection(app: *ui.Frame) !void {
    try caption(app, "grow() in a row, text reflows when the window resizes", .src(@src()));
    try app.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .gap = 12 } },
        .{
            Rect{
                .key = .src(@src()),
                .style = &.{ .width = .grow(), .padding = .init(10, 10, 10, 10), .background = .muted, .radius = .sm },
            },
            Rect{
                .key = .src(@src()),
                .style = &.{ .width = .fixed(120), .padding = .init(10, 10, 10, 10), .background = .accented, .radius = .sm },
            },
        },
    });

    try app.e(.{
        Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .gap = 12 } },
        .{
            growParagraph,
            Rect{
                .key = .src(@src()),
                .style = &.{ .width = .fixed(120), .height = .fixed(60), .background = .accented, .radius = .sm },
            },
        },
    });
}

fn growParagraph(app: *ui.Frame) !void {
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .padding = .init(10, 10, 10, 10), .background = .muted, .radius = .sm },
        },
        .{Text{
            .content = lorem,
            .key = .src(@src()),
            .style = &.{ .wrap = true, .width = .grow() },
        }},
    });
}

fn newlinesSection(app: *ui.Frame) !void {
    try caption(app, "hard \\n breaks combined with soft wrap", .src(@src()));
    try app.e(.{
        Rect{
            .key = .src(@src()),
            .style = &.{ .width = .fixed(320), .padding = .init(10, 10, 10, 10), .background = .muted, .radius = .sm },
        },
        .{Text{
            .content = with_newlines,
            .key = .src(@src()),
            .style = &.{ .wrap = true, .width = .grow() },
        }},
    });
}

fn multiLineInputSection(app: *ui.Frame) !void {
    try caption(app, "TextArea: multi-line, enter inserts a newline, arrow up/down navigate lines; drag the bottom edge to resize height (persists)", .src(@src()));
    try app.e(TextArea{
        .key = .src(@src()),
        .buf = &notes,
        .placeholder = "type a multi-line note... drag the bottom edge to grow it",
        .style = &.{ .width = .fixed(360), .height = .fixed(96) },
    });
}

pub fn deinit() void {
    const active_allocator = allocator orelse return;
    notes.deinit(active_allocator);
    notes = .empty;
    allocator = null;
}
