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
stale_buf: std.ArrayList(ShapedKey),
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
        .stale_buf = .empty,
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
    self.cache.deinit();
}

pub fn getGlyph(self: *Face, codepoint: u21) !glyph.GlyphRecord {
    if (self.cache.get(codepoint)) |rec| return rec;

    const gid = self.tt.codepointGlyphIndex(codepoint);
    const hm = self.tt.glyphHMetrics(gid);
    const advance_em: f32 = @as(f32, @floatFromInt(hm.advance_width)) / self.units_per_em;

    var rec: glyph.GlyphRecord = blk: {
        const verts = self.tt.glyphShape(self.allocator, gid) catch |e| switch (e) {
            error.GlyphNotFound => break :blk .empty,
            else => return e,
        };
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
    const size_q: u32 = @intFromFloat(size_px * 64);
    const probe = ShapedKey{ .text = text, .size_q = size_q };

    const gop = try self.shaped_cache.getOrPutContext(self.allocator, probe, .{});
    if (gop.found_existing) {
        gop.value_ptr.last_used_frame = self.current_frame;
        return .{
            .glyphs = gop.value_ptr.glyphs,
            .width = gop.value_ptr.width,
            .ascender = gop.value_ptr.ascender,
        };
    }
    errdefer _ = self.shaped_cache.removeContext(probe, .{});

    const text_copy = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(text_copy);
    gop.key_ptr.* = .{ .text = text_copy, .size_q = size_q };

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

    gop.value_ptr.* = .{
        .glyphs = out,
        .width = pen_x,
        .ascender = ascender,
        .last_used_frame = self.current_frame,
    };
    return .{ .glyphs = out, .width = pen_x, .ascender = ascender };
}

pub fn lineHeight(self: *Face, size_px: f32) !f32 {
    return self.line_height_em * size_px;
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
    self.current_frame +%= 1;
}
