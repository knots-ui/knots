const std = @import("std");
const TrueType = @import("TrueType");
const curve = @import("curve.zig");
const glyph = @import("glyph.zig");
const GlyphBuilder = @import("GlyphBuilder.zig");

fn unitsPerEm(tt: *const TrueType) u16 {
    const head = tt.table_offsets[@intFromEnum(TrueType.TableId.head)];
    return std.mem.readInt(u16, tt.ttf_bytes[head + 18 ..][0..2], .big);
}

tt: TrueType,
glyph_builder: *GlyphBuilder,
cache: std.AutoHashMap(u32, glyph.GlyphRecord),
shaped_cache: ShapedMap,
wrap_cache: WrapMap,
stale_buf: std.ArrayList(ShapedKey),
stale_wrap_buf: std.ArrayList(WrapKey),
current_frame: u32,
units_per_em: f32,
ascender_em: f32,
line_height_em: f32,
allocator: std.mem.Allocator,

const Face = @This();

const SHAPED_EVICT_AGE: u32 = 2;

const ShapedKey = struct {
    text: []const u8,
    size_q: u32,
};

const ShapedEntry = struct {
    glyphs: []glyph.Shaped,
    width: f32,
    ascender: f32,
    last_used_frame: u32,
};

const ShapedContext = struct {
    pub fn hash(_: ShapedContext, k: ShapedKey) u64 {
        var h = std.hash.Wyhash.init(k.size_q);
        h.update(k.text);
        return h.final();
    }
    pub fn eql(_: ShapedContext, a: ShapedKey, b: ShapedKey) bool {
        return a.size_q == b.size_q and std.mem.eql(u8, a.text, b.text);
    }
};

const ShapedMap = std.HashMapUnmanaged(
    ShapedKey,
    ShapedEntry,
    ShapedContext,
    std.hash_map.default_max_load_percentage,
);

const WrapKey = struct {
    text: []const u8,
    size_q: u32,
    wrap_q: u32,
};

const WrapEntry = struct {
    glyphs: []glyph.Shaped,
    lines: []glyph.Line,
    width: f32,
    height: f32,
    ascender: f32,
    line_height: f32,
    last_used_frame: u32,
};

const WrapContext = struct {
    pub fn hash(_: WrapContext, k: WrapKey) u64 {
        var h = std.hash.Wyhash.init(k.size_q);
        h.update(std.mem.asBytes(&k.wrap_q));
        h.update(k.text);
        return h.final();
    }
    pub fn eql(_: WrapContext, a: WrapKey, b: WrapKey) bool {
        return a.size_q == b.size_q and a.wrap_q == b.wrap_q and std.mem.eql(u8, a.text, b.text);
    }
};

const WrapMap = std.HashMapUnmanaged(
    WrapKey,
    WrapEntry,
    WrapContext,
    std.hash_map.default_max_load_percentage,
);

pub fn init(allocator: std.mem.Allocator, font_data: []const u8, glyph_builder: *GlyphBuilder) !Face {
    const tt = try TrueType.load(font_data);

    const upem: f32 = @floatFromInt(unitsPerEm(&tt));
    const vm = tt.verticalMetrics();
    const ascender_em: f32 = @as(f32, @floatFromInt(vm.ascent)) / upem;
    const line_height_em: f32 = @as(f32, @floatFromInt(vm.ascent - vm.descent + vm.line_gap)) / upem;

    return .{
        .tt = tt,
        .glyph_builder = glyph_builder,
        .cache = .init(allocator),
        .shaped_cache = .empty,
        .wrap_cache = .empty,
        .stale_buf = .empty,
        .stale_wrap_buf = .empty,
        .current_frame = 0,
        .units_per_em = upem,
        .ascender_em = ascender_em,
        .line_height_em = line_height_em,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Face) void {
    var it = self.shaped_cache.iterator();
    while (it.next()) |kv| {
        self.allocator.free(kv.key_ptr.text);
        self.allocator.free(kv.value_ptr.glyphs);
    }
    self.shaped_cache.deinit(self.allocator);
    self.stale_buf.deinit(self.allocator);

    var wit = self.wrap_cache.iterator();
    while (wit.next()) |kv| {
        self.allocator.free(kv.key_ptr.text);
        self.allocator.free(kv.value_ptr.glyphs);
        self.allocator.free(kv.value_ptr.lines);
    }
    self.wrap_cache.deinit(self.allocator);
    self.stale_wrap_buf.deinit(self.allocator);

    self.cache.deinit();
}

pub fn getGlyph(self: *Face, codepoint: u21) !glyph.GlyphRecord {
    if (self.cache.get(codepoint)) |rec| return rec;

    const gid = self.tt.codepointGlyphIndex(codepoint);
    const hm = self.tt.glyphHMetrics(gid);
    const advance_em: f32 = @as(f32, @floatFromInt(hm.advance_width)) / self.units_per_em;

    var rec: glyph.GlyphRecord = blk: {
        const verts = try self.tt.glyphShape(self.allocator, gid);
        defer self.allocator.free(verts);

        const curves = try curve.decomposeVertices(self.allocator, verts, self.units_per_em);
        defer self.allocator.free(curves);

        break :blk try self.glyph_builder.addCurves(curves);
    };
    rec.advance_em = advance_em;

    try self.cache.put(codepoint, rec);
    return rec;
}

/// Shape `text` as a single line at `size_px`. Result is cached for the
/// frame; slice is stable until `endFrame` evicts unused entries.
pub fn shape(self: *Face, text: []const u8, size_px: f32) !glyph.ShapedView {
    const size_q: u32 = @intFromFloat(@round(size_px * 64));
    const probe = ShapedKey{ .text = text, .size_q = size_q };

    if (self.shaped_cache.getEntryContext(probe, .{})) |entry| {
        entry.value_ptr.last_used_frame = self.current_frame;
        return .{
            .glyphs = entry.value_ptr.glyphs,
            .width = entry.value_ptr.width,
            .ascender = entry.value_ptr.ascender,
        };
    }

    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var it = view.iterator();

    var tmp: std.ArrayList(glyph.Shaped) = .empty;
    defer tmp.deinit(self.allocator);

    var pen_x: f32 = 0;
    while (true) {
        const start_cluster: u32 = @intCast(it.i);
        const cp = it.nextCodepoint() orelse break;

        const rec = try self.getGlyph(cp);
        const advance_px = rec.advance_em * size_px;
        try tmp.append(self.allocator, .{
            .record = rec,
            .x = pen_x,
            .advance = advance_px,
            .cluster = start_cluster,
        });
        pen_x += advance_px;
    }

    const out = try tmp.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(out);

    const ascender = self.ascender_em * size_px;

    const text_copy = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(text_copy);

    try self.shaped_cache.putNoClobberContext(
        self.allocator,
        .{ .text = text_copy, .size_q = size_q },
        .{
            .glyphs = out,
            .width = pen_x,
            .ascender = ascender,
            .last_used_frame = self.current_frame,
        },
        .{},
    );

    return .{ .glyphs = out, .width = pen_x, .ascender = ascender };
}

pub fn lineHeight(self: *Face, size_px: f32) !f32 {
    return self.line_height_em * size_px;
}

/// Shape `text` with greedy word-wrap at `wrap_px`. When `wrap_px <= 0`,
/// behaves like a single line per hard `\n` break only. Result is cached
/// per (text, size, wrap) for the frame; slices are stable until eviction.
pub fn shapeWrapped(self: *Face, text: []const u8, size_px: f32, wrap_px: f32) !glyph.ShapedWrappedView {
    const size_q: u32 = @intFromFloat(@round(size_px * 64));
    const wrap_q: u32 = if (wrap_px <= 0) 0 else @intFromFloat(@round(wrap_px * 64));
    const probe = WrapKey{ .text = text, .size_q = size_q, .wrap_q = wrap_q };
    const line_h = self.line_height_em * size_px;
    const ascender = self.ascender_em * size_px;

    if (self.wrap_cache.getEntryContext(probe, .{})) |entry| {
        entry.value_ptr.last_used_frame = self.current_frame;
        return .{
            .lines = entry.value_ptr.lines,
            .width = entry.value_ptr.width,
            .height = entry.value_ptr.height,
            .ascender = entry.value_ptr.ascender,
            .line_height = entry.value_ptr.line_height,
        };
    }

    if (text.len == 0) {
        const out_glyphs = try self.allocator.alloc(glyph.Shaped, 0);
        errdefer self.allocator.free(out_glyphs);
        const out_lines = try self.allocator.alloc(glyph.Line, 0);
        errdefer self.allocator.free(out_lines);
        const text_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_copy);

        try self.wrap_cache.putNoClobberContext(
            self.allocator,
            .{ .text = text_copy, .size_q = size_q, .wrap_q = wrap_q },
            .{
                .glyphs = out_glyphs,
                .lines = out_lines,
                .width = 0,
                .height = line_h,
                .ascender = ascender,
                .line_height = line_h,
                .last_used_frame = self.current_frame,
            },
            .{},
        );

        return .{ .lines = out_lines, .width = 0, .height = line_h, .ascender = ascender, .line_height = line_h };
    }

    const full = try self.shape(text, size_px);

    const out_glyphs = try self.allocator.alloc(glyph.Shaped, full.glyphs.len);
    errdefer self.allocator.free(out_glyphs);

    var lines: std.ArrayList(glyph.Line) = .empty;
    defer lines.deinit(self.allocator);

    // Greedy state.
    var line_start_glyph: usize = 0; // index into full.glyphs
    var line_start_byte: u32 = 0; // byte in `text`
    var line_width: f32 = 0; // committed (line content up to last commit point)
    var word_width: f32 = 0; // in-progress non-blank run
    var blank_width: f32 = 0; // trailing blanks since last word
    var last_break_glyph: ?usize = null; // index AFTER the last good break (start of next word)
    var last_break_byte: u32 = 0;
    var out_idx: usize = 0;
    var max_line_w: f32 = 0;

    const flushLine = struct {
        fn call(
            face: *Face,
            ls: *std.ArrayList(glyph.Line),
            full_glyphs: []const glyph.Shaped,
            out_buf: []glyph.Shaped,
            out_idx_ptr: *usize,
            start_g: usize,
            end_g: usize,
            byte_start: u32,
            byte_end: u32,
            y: f32,
        ) !f32 {
            const base = out_idx_ptr.*;
            const count = end_g - start_g;
            const x0: f32 = if (count > 0) full_glyphs[start_g].x else 0;
            for (full_glyphs[start_g..end_g], 0..) |gl, i| {
                out_buf[base + i] = .{
                    .record = gl.record,
                    .x = gl.x - x0,
                    .advance = gl.advance,
                    .cluster = gl.cluster - byte_start,
                };
            }
            out_idx_ptr.* = base + count;
            const width: f32 = if (count > 0)
                (full_glyphs[end_g - 1].x + full_glyphs[end_g - 1].advance) - x0
            else
                0;
            try ls.append(face.allocator, .{
                .glyphs = out_buf[base .. base + count],
                .byte_start = byte_start,
                .byte_end = byte_end,
                .width = width,
                .y = y,
            });
            return width;
        }
    }.call;

    var i: usize = 0;
    while (i < full.glyphs.len) : (i += 1) {
        const gl = full.glyphs[i];
        const b = gl.cluster;
        const ch: u8 = if (b < text.len) text[b] else 0;
        const is_newline = ch == '\n';
        const is_blank = ch == ' ' or ch == '\t';

        if (is_newline) {
            // Hard break: commit [line_start_glyph .. i), exclude the newline glyph.
            const y = @as(f32, @floatFromInt(lines.items.len)) * line_h;
            const w = try flushLine(self, &lines, full.glyphs, out_glyphs, &out_idx, line_start_glyph, i, line_start_byte, b, y);
            max_line_w = @max(max_line_w, w);
            // Skip the newline glyph itself.
            line_start_glyph = i + 1;
            line_start_byte = b + @as(u32, @intCast(charLen(text, b)));
            line_width = 0;
            word_width = 0;
            blank_width = 0;
            last_break_glyph = null;
            continue;
        }

        if (is_blank) {
            if (word_width > 0) {
                line_width += blank_width + word_width;
                last_break_glyph = i; // break before this blank
                last_break_byte = b;
                blank_width = 0;
                word_width = 0;
            }
            blank_width += gl.advance;
            continue;
        }

        word_width += gl.advance;

        if (wrap_px > 0 and (line_width + blank_width + word_width) > wrap_px) {
            if (last_break_glyph) |bg| {
                // Break at last blank. Line content is [line_start_glyph .. bg).
                const y = @as(f32, @floatFromInt(lines.items.len)) * line_h;
                const w = try flushLine(self, &lines, full.glyphs, out_glyphs, &out_idx, line_start_glyph, bg, line_start_byte, last_break_byte, y);
                max_line_w = @max(max_line_w, w);

                // Skip the run of blanks after the break point.
                var j: usize = bg;
                while (j < full.glyphs.len) : (j += 1) {
                    const cb = full.glyphs[j].cluster;
                    const cc: u8 = if (cb < text.len) text[cb] else 0;
                    if (cc != ' ' and cc != '\t') break;
                }
                line_start_glyph = j;
                line_start_byte = if (j < full.glyphs.len) full.glyphs[j].cluster else @as(u32, @intCast(text.len));
                var carried: f32 = 0;
                var k: usize = j;
                while (k <= i) : (k += 1) carried += full.glyphs[k].advance;
                word_width = carried;
                line_width = 0;
                blank_width = 0;
                last_break_glyph = null;
            } else {
                // Single word > wrap. Mid-word fallback: emit [line_start_glyph .. i).
                if (i > line_start_glyph) {
                    const y = @as(f32, @floatFromInt(lines.items.len)) * line_h;
                    const w = try flushLine(self, &lines, full.glyphs, out_glyphs, &out_idx, line_start_glyph, i, line_start_byte, b, y);
                    max_line_w = @max(max_line_w, w);
                }
                line_start_glyph = i;
                line_start_byte = b;
                line_width = 0;
                blank_width = 0;
                word_width = gl.advance;
            }
        }
    }

    // Flush remainder.
    const y = @as(f32, @floatFromInt(lines.items.len)) * line_h;
    const w = try flushLine(self, &lines, full.glyphs, out_glyphs, &out_idx, line_start_glyph, full.glyphs.len, line_start_byte, @as(u32, @intCast(text.len)), y);
    max_line_w = @max(max_line_w, w);

    const lines_owned = try lines.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(lines_owned);

    const height = @as(f32, @floatFromInt(lines_owned.len)) * line_h;
    const text_copy = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(text_copy);

    try self.wrap_cache.putNoClobberContext(
        self.allocator,
        .{ .text = text_copy, .size_q = size_q, .wrap_q = wrap_q },
        .{
            .glyphs = out_glyphs,
            .lines = lines_owned,
            .width = max_line_w,
            .height = height,
            .ascender = ascender,
            .line_height = line_h,
            .last_used_frame = self.current_frame,
        },
        .{},
    );

    return .{
        .lines = lines_owned,
        .width = max_line_w,
        .height = height,
        .ascender = ascender,
        .line_height = line_h,
    };
}

fn charLen(text: []const u8, byte: u32) usize {
    if (byte >= text.len) return 0;
    return std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
}

pub fn measure(self: *Face, text: []const u8, size_px: f32) !glyph.TextMetrics {
    const line_h = try self.lineHeight(size_px);

    var max_line_width: f32 = 0;
    var line_count: u32 = 1;

    var line_start: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte == '\n' or i == text.len - 1) {
            const line_end = if (byte == '\n') i else i + 1;
            const line = text[line_start..line_end];

            if (line.len > 0) {
                const entry = try self.shape(line, size_px);
                max_line_width = @max(max_line_width, entry.width);
            }

            if (byte == '\n') {
                line_count += 1;
                line_start = i + 1;
            }
        }
    }

    return .{
        .width = max_line_width,
        .height = line_h * @as(f32, @floatFromInt(line_count)),
        .line_count = line_count,
    };
}

/// Advance the frame counter and evict shaped entries unused in the last
/// `SHAPED_EVICT_AGE` frames. Glyph (em-space) cache is never evicted.
pub fn endFrame(self: *Face) void {
    const cur = self.current_frame;
    self.stale_buf.clearRetainingCapacity();

    var it = self.shaped_cache.iterator();
    while (it.next()) |kv| {
        if (cur -% kv.value_ptr.last_used_frame > SHAPED_EVICT_AGE) {
            self.stale_buf.append(self.allocator, kv.key_ptr.*) catch break;
        }
    }
    for (self.stale_buf.items) |k| {
        if (self.shaped_cache.fetchRemoveContext(k, .{})) |kv| {
            self.allocator.free(kv.key.text);
            self.allocator.free(kv.value.glyphs);
        }
    }

    self.stale_wrap_buf.clearRetainingCapacity();
    var wit = self.wrap_cache.iterator();
    while (wit.next()) |kv| {
        if (cur -% kv.value_ptr.last_used_frame > SHAPED_EVICT_AGE) {
            self.stale_wrap_buf.append(self.allocator, kv.key_ptr.*) catch break;
        }
    }
    for (self.stale_wrap_buf.items) |k| {
        if (self.wrap_cache.fetchRemoveContext(k, .{})) |kv| {
            self.allocator.free(kv.key.text);
            self.allocator.free(kv.value.glyphs);
            self.allocator.free(kv.value.lines);
        }
    }

    self.current_frame +%= 1;
}
