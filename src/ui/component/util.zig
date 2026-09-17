const std = @import("std");
const glyph = @import("text").glyph;

pub const Pos = struct { x: f32, y: f32 };

pub const LineSpan = struct { x: f32, y: f32, w: f32 };

pub fn posAtByte(view: glyph.ShapedWrappedView, byte: u32, content_scale: f32) Pos {
    if (view.lines.len == 0) return .{ .x = 0, .y = 0 };

    for (view.lines) |line| {
        if (byte <= line.byte_end) {
            const local = byte -| line.byte_start;
            return .{ .x = xInLine(line, local, content_scale), .y = line.y / content_scale };
        }
    }
    const last = view.lines[view.lines.len - 1];
    return .{ .x = last.width / content_scale, .y = last.y / content_scale };
}

pub fn byteAtPos(view: glyph.ShapedWrappedView, local: Pos, content_scale: f32) u32 {
    if (view.lines.len == 0) return 0;
    const line_h_logical = view.line_height / content_scale;
    var li: usize = 0;
    if (line_h_logical > 0) {
        const f = @floor(local.y / line_h_logical);
        if (f < 0)
            li = 0
        else if (f >= @as(f32, @floatFromInt(view.lines.len)))
            li = view.lines.len - 1
        else
            li = @intFromFloat(f);
    }
    const line = view.lines[li];
    return line.byte_start + byteInLineAtX(line, local.x, content_scale);
}

/// Emit one span per line covered by [lo, hi).
pub fn lineSpansForRange(allocator: std.mem.Allocator, view: glyph.ShapedWrappedView, lo: u32, hi: u32, content_scale: f32) ![]const LineSpan {
    if (lo >= hi or view.lines.len == 0) return &.{};
    var spans: std.ArrayList(LineSpan) = .empty;
    defer spans.deinit(allocator);

    for (view.lines) |line| {
        if (hi <= line.byte_start) break;
        const a = if (lo > line.byte_start) lo - line.byte_start else 0;
        const b = if (hi < line.byte_end) hi - line.byte_start else line.byte_end - line.byte_start;
        if (b <= a) continue;
        const xa = xInLine(line, a, content_scale);
        const xb = xInLine(line, b, content_scale);
        try spans.append(allocator, .{
            .x = xa,
            .y = line.y / content_scale,
            .w = xb - xa,
        });
    }
    return spans.toOwnedSlice(allocator);
}

fn xInLine(line: glyph.Line, line_local_byte: u32, content_scale: f32) f32 {
    for (line.glyphs) |gl| {
        if (gl.cluster >= line_local_byte) return gl.x / content_scale;
    }
    if (line.glyphs.len == 0) return 0;
    const last = line.glyphs[line.glyphs.len - 1];
    return (last.x + last.advance) / content_scale;
}

fn byteInLineAtX(line: glyph.Line, local_x: f32, content_scale: f32) u32 {
    if (line.glyphs.len == 0) return 0;
    for (line.glyphs) |gl| {
        const gx = gl.x / content_scale;
        const gw = gl.advance / content_scale;
        const mid = gx + gw * 0.5;
        if (local_x < mid) return gl.cluster;
    }
    return line.byte_end - line.byte_start;
}
