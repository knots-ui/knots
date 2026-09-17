const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Spacer = ui.component.Spacer;
const Color = ui.Color;
const ColorInput = Color.Input;

const line_height: f32 = 17;
const gutter_width: f32 = 25;
const row_overscan: u32 = 6;
const expanded_width: f32 = 460;
const icon_expand_source = "\u{e86f}";
const icon_collapse_source = "\u{e4f3}";

const Span = struct {
    content: []const u8,
    color: ColorInput,
};

const Line = struct {
    span_start: usize,
    span_end: usize,
};

const Row = struct {
    spans: []const Span,
    gutter_label: []const u8,
};

pub const Highlighted = struct {
    spans: []const Span,
    rows: []const Row,
    gutter_labels: []const []const u8,

    pub fn deinit(self: Highlighted, allocator: std.mem.Allocator) void {
        for (self.gutter_labels) |label| allocator.free(label);
        allocator.free(self.gutter_labels);
        allocator.free(self.rows);
        allocator.free(self.spans);
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    spans: std.ArrayList(Span) = .empty,
    lines: std.ArrayList(Line) = .empty,
    line_start: usize = 0,

    fn appendSpan(self: *Builder, content: []const u8, color: ColorInput) !void {
        if (content.len == 0) return;

        const is_newline = std.mem.eql(u8, content, "\n");
        if (!is_newline and self.spans.items.len > self.line_start) {
            const prev = &self.spans.items[self.spans.items.len - 1];
            if (!std.mem.eql(u8, prev.content, "\n") and std.meta.eql(prev.color, color)) {
                const prev_end = @intFromPtr(prev.content.ptr) + prev.content.len;
                if (prev_end == @intFromPtr(content.ptr)) {
                    prev.content = prev.content.ptr[0 .. prev.content.len + content.len];
                    return;
                }
            }
        }

        try self.spans.append(self.allocator, .{
            .content = content,
            .color = color,
        });
    }

    fn appendSegment(self: *Builder, content: []const u8, color: ColorInput) !void {
        var start: usize = 0;
        while (start < content.len) {
            const nl_rel = std.mem.indexOfScalar(u8, content[start..], '\n');
            const end = if (nl_rel) |idx| start + idx else content.len;
            if (end > start) {
                try self.appendSpan(content[start..end], color);
            }

            if (nl_rel == null) break;

            try self.appendSpan(content[end .. end + 1], .text);
            try self.finishLine();
            start = end + 1;
        }
    }

    fn finishLine(self: *Builder) !void {
        try self.lines.append(self.allocator, .{
            .span_start = self.line_start,
            .span_end = self.spans.items.len,
        });
        self.line_start = self.spans.items.len;
    }

    fn finish(self: *Builder, source_len: usize) !Highlighted {
        if (self.line_start < self.spans.items.len or source_len == 0) {
            try self.finishLine();
        }

        const spans = try self.spans.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(spans);

        const lines = self.lines.items;
        const rows = try self.allocator.alloc(Row, lines.len);
        errdefer self.allocator.free(rows);

        const gutter_labels = try self.allocator.alloc([]const u8, lines.len);
        errdefer self.allocator.free(gutter_labels);

        var labels_created: usize = 0;
        errdefer for (gutter_labels[0..labels_created]) |label| self.allocator.free(label);

        for (lines, rows, 0..) |line, *row, i| {
            const gutter_label = try std.fmt.allocPrint(self.allocator, "{d}", .{i + 1});
            gutter_labels[i] = gutter_label;
            labels_created += 1;
            row.* = .{
                .spans = spans[line.span_start..line.span_end],
                .gutter_label = gutter_label,
            };
        }
        self.lines.deinit(self.allocator);
        self.lines = .empty;

        return .{
            .spans = spans,
            .rows = rows,
            .gutter_labels = gutter_labels,
        };
    }

    fn deinit(self: *Builder) void {
        self.lines.deinit(self.allocator);
        self.spans.deinit(self.allocator);
    }
};

pub fn highlight(allocator: std.mem.Allocator, source: [:0]const u8) !Highlighted {
    var builder = Builder{ .allocator = allocator };
    errdefer builder.deinit();

    var tokenizer = std.zig.Tokenizer.init(source);
    var cursor: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) {
            try appendGap(&builder, source[cursor..source.len]);
            break;
        }

        if (token.loc.start > cursor) {
            try appendGap(&builder, source[cursor..token.loc.start]);
        }

        try builder.appendSegment(source[token.loc.start..token.loc.end], colorForTag(token.tag));
        cursor = token.loc.end;
    }

    return try builder.finish(source.len);
}

pub fn render(
    app: *ui.Frame,
    source_path: []const u8,
    highlighted: ?Highlighted,
    expanded: bool,
) !bool {
    const panel_key = ui.Key.str("code.viewer");
    const panel_w = app.ui().anim(panel_key.hash(), "w", if (expanded) expanded_width else 0, .{
        .duration_ms = 180,
        .ease = .ease_out_cubic,
    });

    if (!expanded and panel_w <= 1) {
        const response = try app.interact(Button{
            .padding = .init(3, 8, 3, 8),
            .@"align" = .center,
            .justify = .center,
            .key = .src(@src()),
            .style = .{
                .color = .muted,
                .corner_radius = .sm,
                .border_width = .all(1),
                .border_color = .toned,
            },
            .hover_style = .{ .border_color = .primary },
            .hover_anim = .{},
            .text = .{ .content = icon_expand_source, .size = .xs },
        });
        return response.clicked;
    }

    const panel = Rect{
        .width = .fixed(panel_w),
        .height = .grow(),
        .padding = .init(12, 12, 12, 12),
        .dir = .column,
        .gap = 10,
        .overflow = .hidden,
        .key = panel_key,
        .style = .{
            .color = .elevated,
            .corner_radius = .lg,
            .border_width = .all(1),
            .border_color = .toned,
        },
    };
    _ = try panel.open(app);

    const toggle = try app.interact(Button{
        .padding = .init(3, 8, 3, 8),
        .@"align" = .center,
        .justify = .center,
        .key = .src(@src()),
        .style = .{ .color = .primary, .corner_radius = .sm },
        .hover_anim = .{},
        .text = .{ .content = icon_collapse_source, .size = .xs },
    });

    const body = Rect{
        .width = .grow(),
        .height = .grow(),
        .dir = .column,
        .overflow = .scroll,
        .key = ui.Key.str(source_path).indexed(0),
        .style = .{
            .corner_radius = .md,
            .border_color = .toned,
        },
    };
    _ = try body.open(app);
    if (highlighted) |h| try renderLines(app, h, source_path);
    try body.close(app);

    try panel.close(app);
    return toggle.clicked;
}

fn renderLines(app: *ui.Frame, highlighted: Highlighted, source_path: []const u8) !void {
    try app.e(ui.control.VirtualList(Row){
        .key = ui.Key.str(source_path).indexed(1),
        .items = highlighted.rows,
        .row_height = line_height,
        .overscan = row_overscan,
        .each = renderLine,
    });
}

fn renderLine(app: *ui.Frame, row_item: Row, line_idx: usize) !void {
    const row = Rect{
        .width = .fit(),
        .height = .fixed(line_height),
        .dir = .row,
        .key = ui.Key.str("code.line").indexed(line_idx),
        .style = .{ .corner_radius = .none },
    };
    _ = try row.open(app);

    try app.e(.{
        Rect{
            .width = .fixed(gutter_width),
            .height = .fixed(line_height),
            .justify = .end,
            .padding = .init(0, 0, 0, 0),
            .key = ui.Key.str("code.gutter").indexed(line_idx),
        },
        .{
            Text{
                .content = row_item.gutter_label,
                .size = .xs,
                .color = .dimmed,
                .selectable = false,
                .font = "jetbrains-mono",
                .key = ui.Key.str("code.gutter.text").indexed(line_idx),
            },
        },
        Spacer{ .width = .fixed(12), .key = ui.Key.str("code.gutter.space").indexed(line_idx) },
    });

    for (row_item.spans, 0..) |span, span_idx| {
        if (std.mem.eql(u8, span.content, "\n")) continue;
        if (span.content.len == 0) continue;

        try app.e(Text{
            .content = span.content,
            .size = .xs,
            .color = span.color,
            .selectable = false,
            .key = ui.Key.str("code.span").indexed(line_idx).indexed(span_idx),
            .font = "jetbrains-mono",
        });
    }

    try row.close(app);
}

fn appendGap(builder: *Builder, gap: []const u8) !void {
    var start: usize = 0;
    while (start < gap.len) {
        if (start + 1 < gap.len and gap[start] == '/' and gap[start + 1] == '/') {
            var end = start + 2;
            while (end < gap.len and gap[end] != '\n') : (end += 1) {}
            try builder.appendSegment(gap[start..end], .dimmed);
            start = end;
            continue;
        }

        var end = start;
        while (end < gap.len) : (end += 1) {
            if (end + 1 < gap.len and gap[end] == '/' and gap[end + 1] == '/') break;
        }
        try builder.appendSegment(gap[start..end], .text);
        start = end;
    }
}

fn colorForTag(tag: std.zig.Token.Tag) ColorInput {
    return switch (tag) {
        .identifier => .text,

        .builtin => .info,

        .string_literal, .multiline_string_literal_line, .char_literal => .success,

        .number_literal => .warning,

        .doc_comment, .container_doc_comment => .dimmed,

        .invalid => .@"error",

        .keyword_pub,
        .keyword_const,
        .keyword_var,
        .keyword_fn,
        .keyword_struct,
        .keyword_enum,
        .keyword_union,
        .keyword_opaque,
        .keyword_extern,
        .keyword_export,
        .keyword_threadlocal,
        .keyword_packed,
        .keyword_noalias,
        .keyword_noinline,
        .keyword_callconv,
        .keyword_addrspace,
        .keyword_align,
        .keyword_allowzero,
        .keyword_anytype,
        .keyword_anyframe,
        .keyword_asm,
        .keyword_linksection,
        .keyword_volatile,
        => .primary,

        .keyword_if,
        .keyword_else,
        .keyword_for,
        .keyword_while,
        .keyword_switch,
        .keyword_return,
        .keyword_break,
        .keyword_continue,
        .keyword_resume,
        .keyword_suspend,
        .keyword_nosuspend,
        .keyword_or,
        .keyword_and,
        .keyword_orelse,
        => .secondary,

        .keyword_try,
        .keyword_catch,
        .keyword_error,
        .keyword_defer,
        .keyword_errdefer,
        .keyword_comptime,
        .keyword_inline,
        .keyword_unreachable,
        .keyword_test,
        => .warning,

        else => .text,
    };
}
