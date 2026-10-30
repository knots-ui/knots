const std = @import("std");
const grapheme = @import("unicode/grapheme.zig");

text: []const u8,
glyphs: Glyphs,
runs: []const Run,
lines: []const Line,
carets: []const Caret = &.{},
caret_offsets: []const f32 = &.{},
width: f32,
height: f32,
ascender: f32,
line_height: f32,
underline_offset: f32 = 0,
underline_thickness: f32 = 0,
/// Glyph store slot of each glyph, filled by `TextSystem.resolveSlots` and valid while
/// `slot_generation` equals the store's generation. `layered_slot` marks COLR glyphs.
slots: []u32 = &.{},
slot_generation: u64 = std.math.maxInt(u64),

pub const layered_slot: u32 = std.math.maxInt(u32);

const TextLayout = @This();

pub const FaceId = u16;

pub const Glyphs = struct {
    ids: []const u32,
    x: []const f64,
    advance: []const f32,
    x_offset: []const f32,
    y_offset: []const f32,
    cluster: []const u32,
    flags: []const u8,

    pub const empty: Glyphs = .{ .ids = &.{}, .x = &.{}, .advance = &.{}, .x_offset = &.{}, .y_offset = &.{}, .cluster = &.{}, .flags = &.{} };
};

pub const Run = struct {
    glyph_start: u32,
    glyph_end: u32,
    face: FaceId,
    size: f32,
};

pub const Line = struct {
    glyph_start: u32,
    glyph_end: u32,
    byte_start: u32,
    byte_end: u32,
    y: f32,
    width: f32,
    baseline: f32,
    height: f32,
};

/// GDEF caret positions inside a ligature glyph, relative to its pen x.
pub const Caret = struct {
    glyph: u32,
    start: u32,
    count: u32,
};

pub const Point = struct { x: f32, y: f32 };

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

pub fn runIndex(self: *const TextLayout, glyph_index: u32) u32 {
    var low: usize = 0;
    var high: usize = self.runs.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (self.runs[mid].glyph_end <= glyph_index) low = mid + 1 else high = mid;
    }
    return @intCast(@min(low, self.runs.len -| 1));
}

/// The first line whose end is at or after `byte`, by binary search.
pub fn lineForByte(self: *const TextLayout, byte: u32) u32 {
    if (self.lines.len == 0) return 0;
    var low: usize = 0;
    var high: usize = self.lines.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (self.lines[mid].byte_end < byte) low = mid + 1 else high = mid;
    }
    return @intCast(@min(low, self.lines.len - 1));
}

pub fn lineForY(self: *const TextLayout, y: f32) u32 {
    if (self.lines.len == 0) return 0;
    var low: usize = 0;
    var high: usize = self.lines.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (self.lines[mid].y + self.lines[mid].height <= y) low = mid + 1 else high = mid;
    }
    return @intCast(@min(low, self.lines.len - 1));
}

pub fn pointForByte(self: *const TextLayout, byte: u32) Point {
    if (self.lines.len == 0) return .{ .x = 0, .y = 0 };
    const last = self.lines[self.lines.len - 1];
    if (byte > last.byte_end) return .{ .x = last.width, .y = last.y };
    const line = self.lines[self.lineForByte(byte)];
    return .{ .x = @floatCast(self.xInLine(line, byte)), .y = line.y };
}

pub fn xForByte(self: *const TextLayout, byte: u32) f64 {
    if (self.lines.len == 0) return 0;
    return self.xInLine(self.lines[self.lineForByte(byte)], byte);
}

pub fn byteForPoint(self: *const TextLayout, point: Point) u32 {
    if (self.lines.len == 0) return 0;
    const line = self.lines[self.lineForY(point.y)];
    return self.byteInLine(line, point.x);
}

/// The glyph whose advance spans `point`, in layout pixels.
pub fn glyphAt(self: *const TextLayout, point: Point) ?u32 {
    if (self.lines.len == 0) return null;
    const line = self.lines[self.lineForY(point.y)];
    if (point.y < line.y or point.y >= line.y + line.height) return null;
    const xs = self.glyphs.x[line.glyph_start..line.glyph_end];
    // The last glyph starting at or before the point.
    const after = lowerBound(xs, @as(f64, point.x) + std.math.floatEps(f64));
    if (after == 0) return null;
    const index = line.glyph_start + after - 1;
    if (point.x >= self.glyphs.x[index] + self.glyphs.advance[index]) return null;
    return index;
}

/// Source bytes of the cluster glyph `index` belongs to.
pub fn clusterBytes(self: *const TextLayout, index: u32) [2]u32 {
    var low: usize = 0;
    var high: usize = self.lines.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (self.lines[mid].glyph_end <= index) low = mid + 1 else high = mid;
    }
    const span = self.clusterAt(self.lines[@min(low, self.lines.len - 1)], index);
    return .{ span.byte_start, span.byte_end };
}

pub fn selectionRects(self: *const TextLayout, allocator: std.mem.Allocator, lo: u32, hi: u32, out: *std.ArrayList(Rect)) !void {
    if (lo >= hi) return;
    for (self.lines) |line| {
        if (hi <= line.byte_start) break;
        const a = @max(lo, line.byte_start);
        const b = @min(hi, line.byte_end);
        if (b <= a) continue;
        const xa: f32 = @floatCast(self.xInLine(line, a));
        const xb: f32 = @floatCast(self.xInLine(line, b));
        try out.append(allocator, .{ .x = xa, .y = line.y, .w = xb - xa, .h = line.height });
    }
}

const ClusterSpan = struct {
    glyph_start: u32,
    glyph_end: u32,
    byte_start: u32,
    byte_end: u32,
};

fn clusterAt(self: *const TextLayout, line: Line, glyph_index: u32) ClusterSpan {
    const clusters = self.glyphs.cluster;
    const cluster = clusters[glyph_index];
    var start = glyph_index;
    while (start > line.glyph_start and clusters[start - 1] == cluster) start -= 1;
    var end = glyph_index + 1;
    while (end < line.glyph_end and clusters[end] == cluster) end += 1;
    const byte_end = self.clusterEnd(line, end);
    return .{ .glyph_start = start, .glyph_end = end, .byte_start = cluster, .byte_end = byte_end };
}

fn clusterEnd(self: *const TextLayout, line: Line, glyph_end: u32) u32 {
    if (glyph_end < line.glyph_end) return self.glyphs.cluster[glyph_end];
    return line.byte_end;
}

fn spanAdvance(self: *const TextLayout, span: ClusterSpan) f64 {
    var total: f64 = 0;
    for (self.glyphs.advance[span.glyph_start..span.glyph_end]) |advance| total += advance;
    return total;
}

fn lineEndX(self: *const TextLayout, line: Line) f64 {
    if (line.glyph_end == line.glyph_start) return 0;
    const last = line.glyph_end - 1;
    return self.glyphs.x[last] + self.glyphs.advance[last];
}

fn xInLine(self: *const TextLayout, line: Line, byte: u32) f64 {
    var index = line.glyph_start;
    while (index < line.glyph_end) : (index += 1) {
        const span = self.clusterAt(line, index);
        index = span.glyph_end - 1;
        if (byte <= span.byte_start) return self.glyphs.x[span.glyph_start];
        if (byte >= span.byte_end) continue;
        const x = self.glyphs.x[span.glyph_start];
        const parts = self.graphemeParts(span, byte);
        if (parts.total <= 1) return x;
        if (self.ligatureCaret(span, parts)) |offset| return x + offset;
        return x + self.spanAdvance(span) * @as(f64, @floatFromInt(parts.before)) / @as(f64, @floatFromInt(parts.total));
    }
    return self.lineEndX(line);
}

const Parts = struct { before: u32, total: u32 };

fn ligatureCaret(self: *const TextLayout, span: ClusterSpan, parts: Parts) ?f64 {
    if (span.glyph_end - span.glyph_start != 1 or parts.before == 0) return null;
    const caret = self.caretOf(span.glyph_start) orelse return null;
    if (caret.count + 1 < parts.total) return null;
    return self.caret_offsets[caret.start + parts.before - 1];
}

fn caretOf(self: *const TextLayout, glyph_index: u32) ?Caret {
    var low: usize = 0;
    var high: usize = self.carets.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (self.carets[mid].glyph < glyph_index) low = mid + 1 else high = mid;
    }
    if (low >= self.carets.len or self.carets[low].glyph != glyph_index) return null;
    return self.carets[low];
}

fn graphemeParts(self: *const TextLayout, span: ClusterSpan, byte: u32) Parts {
    var iterator = grapheme.Iterator.init(self.text[span.byte_start..span.byte_end]);
    var parts: Parts = .{ .before = 0, .total = 0 };
    while (iterator.next()) |end| {
        parts.total += 1;
        if (span.byte_start + end <= byte) parts.before += 1;
    }
    return parts;
}

fn byteInLine(self: *const TextLayout, line: Line, x: f32) u32 {
    var index = line.glyph_start;
    while (index < line.glyph_end) : (index += 1) {
        const span = self.clusterAt(line, index);
        index = span.glyph_end - 1;
        const start = self.glyphs.x[span.glyph_start];
        const advance = self.spanAdvance(span);
        if (x >= start + advance) continue;
        return self.nearestGraphemeBoundary(span, x - start, advance);
    }
    return line.byte_end;
}

fn nearestGraphemeBoundary(self: *const TextLayout, span: ClusterSpan, offset: f64, advance: f64) u32 {
    const count = self.graphemeParts(span, span.byte_end).total;
    if (count <= 1 or advance <= 0) {
        if (offset < advance * 0.5) return span.byte_start;
        return span.byte_end;
    }
    const part = advance / @as(f64, @floatFromInt(count));
    const wanted: u32 = @intFromFloat(@round(offset / part));
    if (wanted == 0) return span.byte_start;
    var iterator = grapheme.Iterator.init(self.text[span.byte_start..span.byte_end]);
    var seen: u32 = 0;
    while (iterator.next()) |end| {
        seen += 1;
        if (seen == wanted) return span.byte_start + @as(u32, @intCast(end));
    }
    return span.byte_end;
}

pub fn visibleLines(self: *const TextLayout, top: f32, bottom: f32) struct { start: u32, end: u32 } {
    if (self.lines.len == 0) return .{ .start = 0, .end = 0 };
    const start = self.lineForY(top);
    var end = start;
    while (end < self.lines.len and self.lines[end].y < bottom) end += 1;
    return .{ .start = start, .end = @intCast(end) };
}

pub fn visibleGlyphs(self: *const TextLayout, line: Line, left: f64, right: f64, overhang: f64) struct { start: u32, end: u32 } {
    const xs = self.glyphs.x[line.glyph_start..line.glyph_end];
    const start = lowerBound(xs, left - overhang);
    const end = lowerBound(xs, right + overhang);
    return .{ .start = line.glyph_start + start, .end = line.glyph_start + end };
}

fn lowerBound(xs: []const f64, value: f64) u32 {
    var low: usize = 0;
    var high: usize = xs.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (xs[mid] < value) low = mid + 1 else high = mid;
    }
    return @intCast(low);
}
