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
const gutter_gap: f32 = 12;
const row_overscan: u32 = 6;
const divider_width: f32 = 12;
const width_min: f32 = 260;
const copied_ms = 1200;
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
    /// The line in the source, without its newline.
    text: []const u8 = "",
};

pub const Highlighted = struct {
    source: []const u8,
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
            .source = "",
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

    var highlighted = try builder.finish(source.len);
    highlighted.source = source;
    var lines = std.mem.splitScalar(u8, source, '\n');
    for (@constCast(highlighted.rows)) |*row| row.text = lines.next() orelse "";
    return highlighted;
}

/// A place between two characters: `column` counts characters, not bytes.
pub const Position = struct {
    line: usize = 0,
    column: usize = 0,

    fn order(a: Position, b: Position) std.math.Order {
        if (a.line != b.line) return std.math.order(a.line, b.line);
        return std.math.order(a.column, b.column);
    }
};

/// What the viewer remembers between frames.
pub const Viewer = struct {
    open: bool = true,
    width: f32 = 460,
    anchor: Position = .{},
    cursor: Position = .{},
    selecting: bool = false,
    /// The pointer x and the width when a divider drag began.
    resize_from: ?[2]f32 = null,
    copied_at_ms: ?i64 = null,

    pub fn clearSelection(self: *Viewer) void {
        self.anchor = .{};
        self.cursor = .{};
        self.selecting = false;
    }

    fn range(self: *const Viewer) [2]Position {
        return if (self.anchor.order(self.cursor) == .gt) .{ self.cursor, self.anchor } else .{ self.anchor, self.cursor };
    }

    /// The selected source text, empty when nothing is selected.
    fn selected(self: *const Viewer, highlighted: Highlighted) []const u8 {
        const lo, const hi = self.range();
        return highlighted.source[byteOffset(highlighted, lo)..byteOffset(highlighted, hi)];
    }
};

fn byteOffset(highlighted: Highlighted, position: Position) usize {
    if (highlighted.rows.len == 0) return 0;
    const text = highlighted.rows[@min(position.line, highlighted.rows.len - 1)].text;
    const line_start = @intFromPtr(text.ptr) - @intFromPtr(highlighted.source.ptr);
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    var column: usize = 0;
    while (column < position.column) : (column += 1) _ = view.nextCodepointSlice() orelse break;
    return line_start + view.i;
}

fn columnCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

const divider_line: ui.Style = .{
    .width = .fixed(2),
    .height = .grow(),
    .radius = .{ .fixed = 1 },
    .background = .transparent,
    .transition = .{ .duration_ms = 120 },
};

/// The divider, then the source panel, or a button that opens it.
pub fn render(frame: *ui.Frame, source_path: []const u8, highlighted: ?Highlighted, viewer: *Viewer) !void {
    const ui_ = frame.ui();
    const panel_key = ui.Key.str("code.viewer");
    const width_max = @max(width_min, @as(f32, @floatFromInt(frame.input().logical_extent.width)) * 0.6);
    const panel_w = ui_.anim(panel_key.hash(), "w", if (viewer.open) std.math.clamp(viewer.width, width_min, width_max) else 0, .{
        // Follows the pointer while the divider is dragged.
        .duration_ms = if (viewer.resize_from != null) 0 else 180,
        .ease = .ease_out_cubic,
    });

    if (!viewer.open and panel_w <= 1) {
        try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .width = .fixed(divider_width) } });
        const response = try frame.interact(Button{
            .key = .src(@src()),
            .label = icon_expand_source,
            .style = &comptime icon_button.with(.{ .width = .fixed(28), .height = .fixed(28), .background = .elevated, .border_width = .all(1), .border_color = .toned }),
        });
        if (response.clicked) {
            viewer.open = true;
            frame.requestRedraw();
        }
        return;
    }

    try divider(frame, viewer, width_max);

    const panel = Rect{
        .key = panel_key,
        .style = &.{
            .width = .fixed(panel_w),
            .height = .grow(),
            .padding = .all(12),
            .direction = .column,
            .gap = 10,
            .overflow = .hidden,
            .background = .elevated,
            .radius = .lg,
            .border_width = .all(1),
            .border_color = .toned,
        },
    };
    _ = try panel.open(frame);
    try header(frame, source_path, highlighted, viewer);

    const body = Rect{
        .key = ui.Key.str(source_path).indexed(0),
        // Every line inherits the monospace font and size from here.
        .style = &.{
            .width = .grow(),
            .height = .grow(),
            .direction = .column,
            .overflow = .scroll,
            .radius = .md,
            .font = "jetbrains-mono",
            .font_size = .xs,
        },
    };
    const body_id = try body.open(frame);
    if (highlighted) |h| {
        const advance = try characterWidth(frame);
        try select(frame, h, viewer, body_id, advance);
        try renderLines(frame, h, viewer, source_path, advance);
    }
    try body.close(frame);

    try panel.close(frame);
}

fn divider(frame: *ui.Frame, viewer: *Viewer, width_max: f32) !void {
    const ui_ = frame.ui();
    const key = ui.Key.str("code.divider");
    const id = key.hash();
    const dragging = viewer.resize_from != null;
    const st = ui_.states(id, .{ .active = dragging });
    _ = try ui_.openStyled(key, .{ .base = &.{ .width = .fixed(divider_width), .height = .grow(), .justify = .center }, .user = &.{} }, st, .{ .interactive = true });
    try frame.e(Rect{
        .key = key.indexed(1),
        .style = if (st.hover or dragging) &comptime divider_line.with(.{ .background = .accent }) else &divider_line,
    });
    ui_.close();

    if (st.hover or dragging) ui_.requestCursor(.resize_horizontal);
    const x: f32 = @floatCast(ui_.input.mouse_pos[0]);
    if (ui_.leftPressed(id, .within)) viewer.resize_from = .{ x, viewer.width };
    if (viewer.resize_from) |from| {
        if (ui_.input.mouseButton(.left).down) {
            // The panel is right of the divider, so dragging left widens it.
            viewer.width = std.math.clamp(from[1] - (x - from[0]), width_min, width_max);
        } else viewer.resize_from = null;
        frame.requestRedraw();
    }
}

/// Small borderless buttons for the header icons.
const icon_button: ui.Style = .{
    .width = .fixed(26),
    .height = .fixed(24),
    .padding = .all(0),
    .radius = .sm,
    .font_size = .sm,
    .background = .transparent,
    .foreground = .dimmed,
    .hover = &.{ .background = .muted, .foreground = .text, .state_layer = 0 },
    .active = &.{ .background = .toned, .state_layer = 0 },
    .transition = .{ .duration_ms = 120 },
};
const icon_copy = "\u{e14d}";
const icon_copied = "\u{e5ca}";

fn header(frame: *ui.Frame, source_path: []const u8, highlighted: ?Highlighted, viewer: *Viewer) !void {
    const row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .@"align" = .center, .gap = 6 } };
    _ = try row.open(frame);
    if ((try frame.interact(Button{
        .key = .src(@src()),
        .label = icon_collapse_source,
        .style = &icon_button,
    })).clicked) {
        viewer.open = false;
        frame.requestRedraw();
    }
    try frame.e(Text{
        .content = source_path,
        .selectable = false,
        .key = .src(@src()),
        .style = &.{ .width = .grow(), .font = "jetbrains-mono", .font_size = .xs, .foreground = .dimmed },
    });

    const now = frame.input().now_ms;
    const copied = if (viewer.copied_at_ms) |at| now - at < copied_ms else false;
    if (copied) frame.requestRedraw();
    const selection = if (highlighted) |h| viewer.selected(h) else "";
    const tooltip = ui.component.Tooltip{
        .key = .src(@src()),
        .content = if (copied) "Copied" else if (selection.len > 0) "Copy selection" else "Copy file",
    };
    _ = try tooltip.open(frame);
    const copy = try frame.interact(Button{
        .key = .src(@src()),
        .label = if (copied) icon_copied else icon_copy,
        .disabled = highlighted == null,
        .style = if (copied) &comptime icon_button.with(.{ .foreground = .success, .hover = &.{ .background = .muted, .foreground = .success, .state_layer = 0 } }) else &icon_button,
    });
    try tooltip.close(frame);
    if (copy.clicked) {
        try frame.writeClipboard(if (selection.len > 0) selection else highlighted.?.source);
        viewer.copied_at_ms = now;
        frame.requestRedraw();
    }
    try row.close(frame);
}

/// JetBrains Mono gives every character the same advance.
fn characterWidth(frame: *ui.Frame) !f32 {
    const ui_ = frame.ui();
    const content = ui_.parentContent();
    const sample = "0000000000";
    const layout = try ui_.textLayout(sample, content.font_size, content.font, 0);
    return layout.width / ui_.content_scale / sample.len;
}

/// Mouse selection, from the layout of the previous frame.
fn select(frame: *ui.Frame, highlighted: Highlighted, viewer: *Viewer, body_id: u64, advance: f32) !void {
    const ui_ = frame.ui();
    const measured = ui_.state.get(.measured, body_id) orelse return;
    if (measured.box.w() <= 0 or highlighted.rows.len == 0) return;
    const area: TextArea = .{ .box = measured.box, .scroll = ui_.state.getScroll(body_id), .advance = advance };

    const left = ui_.input.mouseButton(.left);
    if (area.contains(ui_.input.mouse_pos)) ui_.requestCursor(.text);
    // A fast drag can move the pointer within the frame of the press.
    const pressed_at = left.pressed_pos orelse ui_.input.mouse_pos;
    if (left.pressed and area.contains(pressed_at)) {
        viewer.anchor = area.position(highlighted, pressed_at);
        viewer.cursor = area.position(highlighted, ui_.input.mouse_pos);
        viewer.selecting = left.down;
        frame.requestRedraw();
    } else if (viewer.selecting) {
        viewer.cursor = area.position(highlighted, left.released_pos orelse ui_.input.mouse_pos);
        viewer.selecting = left.down;
        frame.requestRedraw();
    }

    // Cmd/Ctrl+C copies it, like selected Text.
    const selected = viewer.selected(highlighted);
    if (selected.len > 0) ui_.state.selection_text = selected;
}

/// Where the lines are, to map the pointer to a `Position`.
const TextArea = struct {
    box: @FieldType(ui.State.Measured, "box"),
    scroll: [2]f32,
    advance: f32,

    fn contains(self: TextArea, point: [2]f64) bool {
        const x: f32 = @floatCast(point[0]);
        const y: f32 = @floatCast(point[1]);
        return x >= self.box.x() and x < self.box.x() + self.box.w() and y >= self.box.y() and y < self.box.y() + self.box.h();
    }

    /// The nearest position, clamped to the text when `point` is outside it.
    fn position(self: TextArea, highlighted: Highlighted, point: [2]f64) Position {
        const x: f32 = @floatCast(point[0]);
        const y: f32 = @floatCast(point[1]);
        const line_f = @floor((y - self.box.y() + self.scroll[1]) / line_height);
        const line: usize = if (line_f < 0) 0 else @min(@as(usize, @intFromFloat(line_f)), highlighted.rows.len - 1);
        const column_f = @round((x - self.box.x() + self.scroll[0] - gutter_width - gutter_gap) / self.advance);
        const columns = columnCount(highlighted.rows[line].text);
        return .{ .line = line, .column = if (column_f < 0) 0 else @min(@as(usize, @intFromFloat(column_f)), columns) };
    }
};

const VisibleLine = struct {
    row: Row,
    /// Selected columns; `end` past the last character covers the newline.
    selection: ?[2]usize,
    advance: f32,
};

fn renderLines(frame: *ui.Frame, highlighted: Highlighted, viewer: *const Viewer, source_path: []const u8, advance: f32) !void {
    const lo, const hi = viewer.range();
    const lines = try frame.arena().alloc(VisibleLine, highlighted.rows.len);
    for (lines, highlighted.rows, 0..) |*line, row, index| {
        const selected = lo.order(hi) == .lt and index >= lo.line and index <= hi.line;
        line.* = .{
            .row = row,
            .advance = advance,
            .selection = if (selected) .{
                if (index == lo.line) lo.column else 0,
                if (index == hi.line) hi.column else columnCount(row.text) + 1,
            } else null,
        };
    }
    try frame.e(ui.control.VirtualList(VisibleLine){
        .key = ui.Key.str(source_path).indexed(1),
        .items = lines,
        .row_height = line_height,
        .overscan = row_overscan,
        .each = renderLine,
    });
}

fn renderLine(frame: *ui.Frame, line: VisibleLine, line_idx: usize) !void {
    const row = Rect{
        .key = ui.Key.str("code.line").indexed(line_idx),
        .style = &.{ .height = .fixed(line_height), .direction = .row },
    };
    _ = try row.open(frame);

    try frame.e(.{
        Rect{
            .key = ui.Key.str("code.gutter").indexed(line_idx),
            .style = &.{ .width = .fixed(gutter_width), .height = .fixed(line_height), .justify = .end },
        },
        .{
            Text{
                .content = line.row.gutter_label,
                .style = &.{ .foreground = .dimmed },
                .selectable = false,
                .key = ui.Key.str("code.gutter.text").indexed(line_idx),
            },
        },
        Spacer{ .style = &.{ .width = .fixed(gutter_gap) }, .key = ui.Key.str("code.gutter.space").indexed(line_idx) },
    });

    // The selection highlight sits under the code.
    const code = Rect{ .key = ui.Key.str("code.text").indexed(line_idx), .style = &.{ .height = .fixed(line_height), .direction = .layer } };
    _ = try code.open(frame);
    if (line.selection) |columns| {
        const start: f32 = @floatFromInt(columns[0]);
        const end: f32 = @floatFromInt(columns[1]);
        try frame.e(.{
            Rect{ .key = ui.Key.str("code.selection").indexed(line_idx), .style = &.{ .height = .fixed(line_height), .direction = .row } },
            .{
                Spacer{ .key = ui.Key.str("code.selection.lead").indexed(line_idx), .style = &.{ .width = .fixed(start * line.advance) } },
                Rect{
                    .key = ui.Key.str("code.selection.fill").indexed(line_idx),
                    .style = &.{ .width = .fixed((end - start) * line.advance), .height = .fixed(line_height), .background = .accent, .opacity = 0.35 },
                },
            },
        });
    }
    // One text per line, colored by spans, so ligatures can form across tokens.
    const arena = frame.arena();
    var content: std.ArrayList(u8) = .empty;
    var colors: std.ArrayList(ui.Decoration.ColorSpan) = .empty;
    const scope = frame.ui().parentContent();
    for (line.row.spans) |span| {
        if (std.mem.eql(u8, span.content, "\n")) continue;
        if (span.content.len == 0) continue;
        const start: u32 = @intCast(content.items.len);
        try content.appendSlice(arena, span.content);
        try colors.append(arena, .{ .start = start, .end = @intCast(content.items.len), .color = scope.color(span.color, &frame.ui().theme) });
    }
    if (content.items.len > 0) {
        try frame.e(Text{
            .content = content.items,
            .colors = colors.items,
            .selectable = false,
            .key = ui.Key.str("code.spans").indexed(line_idx),
        });
    }
    try code.close(frame);

    try row.close(frame);
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
