const std = @import("std");
const ft = @import("freetype").c;
const hb = @import("harfbuzz").c;
const Atlas = @import("Atlas.zig");
const glyph = @import("glyph.zig");

ft_face: ft.FT_Face,
hb_font: *hb.hb_font_t,
hb_buf: *hb.hb_buffer_t,
atlas: *Atlas,
cache: std.AutoHashMap(glyph.Key, glyph.Metrics),
shaped_cache: ShapedMap,
current_frame: u32,
last_size_q: u32,
allocator: std.mem.Allocator,

const Face = @This();

const SHAPED_EVICT_AGE: u32 = 2;

const ShapedContext = struct {
    pub fn hash(_: ShapedContext, k: glyph.ShapedKey) u64 {
        var h = std.hash.Wyhash.init(k.size_q);
        h.update(k.text);
        return h.final();
    }
    pub fn eql(_: ShapedContext, a: glyph.ShapedKey, b: glyph.ShapedKey) bool {
        return a.size_q == b.size_q and std.mem.eql(u8, a.text, b.text);
    }
};

const ShapedMap = std.HashMapUnmanaged(
    glyph.ShapedKey,
    glyph.ShapedEntry,
    ShapedContext,
    std.hash_map.default_max_load_percentage,
);

pub fn init(allocator: std.mem.Allocator, ft_lib: ft.FT_Library, font_data: []const u8, atlas: *Atlas) !Face {
    var ft_face: ft.FT_Face = undefined;
    if (ft.FT_New_Memory_Face(ft_lib, font_data.ptr, @intCast(font_data.len), 0, &ft_face) != 0)
        return error.FontLoadFailed;

    const hb_font = hb.hb_ft_font_create(@ptrCast(ft_face), null) orelse return error.HarfBuzzFontFailed;
    const hb_buf = hb.hb_buffer_create() orelse return error.HarfBuzzBufferFailed;

    return .{
        .ft_face = ft_face,
        .hb_font = hb_font,
        .hb_buf = hb_buf,
        .atlas = atlas,
        .cache = .init(allocator),
        .shaped_cache = .empty,
        .current_frame = 0,
        .last_size_q = 0,
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
    self.cache.deinit();
    hb.hb_buffer_destroy(self.hb_buf);
    hb.hb_font_destroy(self.hb_font);
    _ = ft.FT_Done_Face(self.ft_face);
}

fn rasterizeGlyph(self: *Face, codepoint: u32, size_px: f32) !glyph.Metrics {
    const key = glyph.Key{
        .codepoint = codepoint,
        .size_px = @intFromFloat(size_px * 64),
    };

    if (self.cache.get(key)) |metrics| return metrics;

    if (ft.FT_Load_Glyph(self.ft_face, codepoint, ft.FT_LOAD_TARGET_LIGHT) != 0)
        return error.LoadGlyphFailed;
    if (ft.FT_Render_Glyph(self.ft_face.*.glyph, ft.FT_RENDER_MODE_NORMAL) != 0)
        return error.RenderGlyphFailed;

    const g = self.ft_face.*.glyph;
    const bmp = g.*.bitmap;

    const atlas_rect = if (bmp.width > 0 and bmp.rows > 0) blk: {
        const bitmap_data = bmp.buffer[0 .. bmp.width * bmp.rows];
        break :blk try self.atlas.pack(bitmap_data, bmp.width, bmp.rows);
    } else glyph.Rect{
        .u = 0,
        .v = 0,
        .uw = 0,
        .uh = 0,
        .width = 0,
        .height = 0,
    };

    const metrics = glyph.Metrics{
        .rect = atlas_rect,
        .bearing_x = @floatFromInt(g.*.bitmap_left),
        .bearing_y = @floatFromInt(g.*.bitmap_top),
        .advance = @as(f32, @floatFromInt(g.*.advance.x)) / 64.0,
    };

    try self.cache.put(key, metrics);
    return metrics;
}

/// Shape `text` as a single line at `size_px`. The result is cached and
/// returned by value as a `ShapedView` whose `glyphs` slice borrows from
/// the cache. The slice is stable for the rest of the frame; `endFrame`
/// is the only point at which entries are freed.
pub fn shape(self: *Face, text: []const u8, size_px: f32) !glyph.ShapedView {
    const size_q: u32 = @intFromFloat(size_px * 64);
    const probe = glyph.ShapedKey{ .text = text, .size_q = size_q };

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

    try self.setSizeQ(size_q);
    self.shapeText(text);

    var glyph_count: u32 = 0;
    const glyph_infos = hb.hb_buffer_get_glyph_infos(self.hb_buf, &glyph_count);
    const glyph_positions = hb.hb_buffer_get_glyph_positions(self.hb_buf, &glyph_count);

    const out = try self.allocator.alloc(glyph.Shaped, glyph_count);
    errdefer self.allocator.free(out);
    var pen_x: f32 = 0;

    for (0..glyph_count) |i| {
        const codepoint = glyph_infos[i].codepoint;
        const metrics = try self.rasterizeGlyph(codepoint, size_px);
        const x_offset = @as(f32, @floatFromInt(glyph_positions[i].x_offset)) / 64.0;
        const y_offset = @as(f32, @floatFromInt(glyph_positions[i].y_offset)) / 64.0;

        out[i] = .{
            .metrics = metrics,
            .x = @round(pen_x + x_offset + metrics.bearing_x),
            .y = y_offset,
            .cluster = glyph_infos[i].cluster,
        };

        pen_x += @as(f32, @floatFromInt(glyph_positions[i].x_advance)) / 64.0;
    }

    const ascender = @as(f32, @floatFromInt(self.ft_face.*.size.*.metrics.ascender)) / 64.0;

    gop.value_ptr.* = .{
        .glyphs = out,
        .width = pen_x,
        .ascender = ascender,
        .last_used_frame = self.current_frame,
    };
    return .{ .glyphs = out, .width = pen_x, .ascender = ascender };
}

fn setSizeQ(self: *Face, size_q: u32) !void {
    if (self.last_size_q == size_q) return;
    if (ft.FT_Set_Char_Size(self.ft_face, 0, @intCast(size_q), 96, 96) != 0)
        return error.SetSizeFailed;
    hb.hb_ft_font_changed(self.hb_font);
    self.last_size_q = size_q;
}

fn shapeText(self: *Face, text: []const u8) void {
    hb.hb_buffer_reset(self.hb_buf);
    hb.hb_buffer_add_utf8(self.hb_buf, text.ptr, @intCast(text.len), 0, @intCast(text.len));
    hb.hb_buffer_guess_segment_properties(self.hb_buf);
    hb.hb_shape(self.hb_font, self.hb_buf, null, 0);
}

pub fn lineHeight(self: *Face, size_px: f32) !f32 {
    try self.setSizeQ(@intFromFloat(size_px * 64));
    return @as(f32, @floatFromInt(self.ft_face.*.size.*.metrics.height)) / 64.0;
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

/// Advance the frame counter and evict shaped entries that have not been
/// touched in the last `SHAPED_EVICT_AGE` frames. Callers must invoke this
/// once per frame after all shape() calls for the frame are done.
pub fn endFrame(self: *Face) void {
    const cur = self.current_frame;
    var stale: std.ArrayList(glyph.ShapedKey) = .empty;
    defer stale.deinit(self.allocator);

    var it = self.shaped_cache.iterator();
    while (it.next()) |kv| {
        if (cur -% kv.value_ptr.last_used_frame > SHAPED_EVICT_AGE) {
            stale.append(self.allocator, kv.key_ptr.*) catch break;
        }
    }
    for (stale.items) |k| {
        if (self.shaped_cache.fetchRemoveContext(k, .{})) |kv| {
            self.allocator.free(kv.key.text);
            self.allocator.free(kv.value.glyphs);
        }
    }
    self.current_frame +%= 1;
}
