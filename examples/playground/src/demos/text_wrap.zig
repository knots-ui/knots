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

notes: std.ArrayList(u8) = .empty,

pub fn render(self: *@This(), app: *knots.App, frame: *ui.Frame) !void {
    const root = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .column, .gap = 16 } };
    _ = try root.open(frame);
    try fixedWidthSection(frame);
    try growWidthSection(frame);
    try newlinesSection(frame);
    try multiLineInputSection(frame, &self.notes, app.allocator);
    try root.close(frame);
}

fn caption(frame: *ui.Frame, comptime label: []const u8, key: ui.Key) !void {
    try frame.e(Text{
        .content = label,
        .key = key,
        .style = &.{ .font_size = .xs, .foreground = .dimmed },
    });
}

fn fixedWidthSection(frame: *ui.Frame) !void {
    try caption(frame, "fixed(220) container, text wraps inside a narrow column", .src(@src()));
    try frame.e(.{
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

fn growWidthSection(frame: *ui.Frame) !void {
    try caption(frame, "grow() in a row, text reflows when the window resizes", .src(@src()));
    try frame.e(.{
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

    try frame.e(.{
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

fn growParagraph(frame: *ui.Frame) !void {
    try frame.e(.{
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

fn newlinesSection(frame: *ui.Frame) !void {
    try caption(frame, "hard \\n breaks combined with soft wrap", .src(@src()));
    try frame.e(.{
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

fn multiLineInputSection(frame: *ui.Frame, notes: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try caption(frame, "TextArea: multi-line, enter inserts a newline, arrow up/down navigate lines; drag the bottom edge to resize height (persists)", .src(@src()));
    try frame.e(TextArea{
        .key = .src(@src()),
        .buf = notes,
        .allocator = allocator,
        .placeholder = "type a multi-line note... drag the bottom edge to grow it",
        .style = &.{ .width = .fixed(360), .height = .fixed(96) },
    });
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.notes.deinit(allocator);
}
