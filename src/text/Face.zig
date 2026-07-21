const std = @import("std");
const TrueType = @import("TrueType");
const curve = @import("curve.zig");
const glyph = @import("glyph.zig");
const GlyphBuilder = @import("GlyphBuilder.zig");

true_type: TrueType,
glyph_builder: *GlyphBuilder,
glyph_cache: std.AutoHashMap(u32, glyph.GlyphRecord),
shaped_cache: ShapedMap,
wrap_cache: WrapMap,
stale_shaped_keys: std.ArrayList(ShapedKey),
stale_wrap_keys: std.ArrayList(WrapKey),
current_frame: u32,
units_per_em: f32,
ascender_em: f32,
line_height_em: f32,
allocator: std.mem.Allocator,

const Face = @This();

// Bounds keep cache memory and end-of-frame eviction latency predictable.
const cache_evict_age_frames: u32 = 2;
const cache_entry_count_max: u32 = 4096;
const cache_evictions_per_frame_max: u32 = 256;
pub const text_bytes_max: u32 = 1024 * 1024;
const quantized_pixel_exclusive_max: f32 = 4294967296.0;

comptime {
    std.debug.assert(cache_evict_age_frames > 0);
    std.debug.assert(cache_evictions_per_frame_max <= cache_entry_count_max);
}

const ShapedKey = struct {
    text: []const u8,
    size_quantized: u32,
};

const ShapedEntry = struct {
    glyphs: []glyph.Shaped,
    width: f32,
    ascender: f32,
    last_used_frame: u32,
};

const ShapedContext = struct {
    pub fn hash(_: ShapedContext, key: ShapedKey) u64 {
        var hasher = std.hash.Wyhash.init(key.size_quantized);
        hasher.update(key.text);
        return hasher.final();
    }

    pub fn eql(_: ShapedContext, key_a: ShapedKey, key_b: ShapedKey) bool {
        if (key_a.size_quantized != key_b.size_quantized) return false;
        return std.mem.eql(u8, key_a.text, key_b.text);
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
    size_quantized: u32,
    wrap_quantized: u32,
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
    pub fn hash(_: WrapContext, key: WrapKey) u64 {
        var hasher = std.hash.Wyhash.init(key.size_quantized);
        hasher.update(std.mem.asBytes(&key.wrap_quantized));
        hasher.update(key.text);
        return hasher.final();
    }

    pub fn eql(_: WrapContext, key_a: WrapKey, key_b: WrapKey) bool {
        if (key_a.size_quantized != key_b.size_quantized) return false;
        if (key_a.wrap_quantized != key_b.wrap_quantized) return false;
        return std.mem.eql(u8, key_a.text, key_b.text);
    }
};

const WrapMap = std.HashMapUnmanaged(
    WrapKey,
    WrapEntry,
    WrapContext,
    std.hash_map.default_max_load_percentage,
);

fn readUnitsPerEm(true_type: *const TrueType) !u16 {
    const table_offset = true_type.table_offsets[@intFromEnum(TrueType.TableId.head)];
    if (table_offset > true_type.ttf_bytes.len) return error.InvalidFont;
    if (true_type.ttf_bytes.len - table_offset < 20) return error.InvalidFont;

    const units_per_em = std.mem.readInt(
        u16,
        true_type.ttf_bytes[table_offset + 18 ..][0..2],
        .big,
    );
    if (units_per_em == 0) return error.InvalidFont;
    return units_per_em;
}

pub fn init(allocator: std.mem.Allocator, font_data: []const u8, glyph_builder: *GlyphBuilder) !Face {
    const true_type = try TrueType.load(font_data);
    const units_per_em: f32 = @floatFromInt(try readUnitsPerEm(&true_type));
    const vertical_metrics = true_type.verticalMetrics();
    const ascender_em =
        @as(f32, @floatFromInt(vertical_metrics.ascent)) / units_per_em;
    const line_height_em = @as(
        f32,
        @floatFromInt(
            vertical_metrics.ascent - vertical_metrics.descent + vertical_metrics.line_gap,
        ),
    ) / units_per_em;

    var stale_shaped_keys = try std.ArrayList(ShapedKey).initCapacity(
        allocator,
        cache_evictions_per_frame_max,
    );
    errdefer stale_shaped_keys.deinit(allocator);
    var stale_wrap_keys = try std.ArrayList(WrapKey).initCapacity(
        allocator,
        cache_evictions_per_frame_max,
    );
    errdefer stale_wrap_keys.deinit(allocator);

    return .{
        .true_type = true_type,
        .glyph_builder = glyph_builder,
        .glyph_cache = .init(allocator),
        .shaped_cache = .empty,
        .wrap_cache = .empty,
        .stale_shaped_keys = stale_shaped_keys,
        .stale_wrap_keys = stale_wrap_keys,
        .current_frame = 0,
        .units_per_em = units_per_em,
        .ascender_em = ascender_em,
        .line_height_em = line_height_em,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Face) void {
    var shaped_iterator = self.shaped_cache.iterator();
    while (shaped_iterator.next()) |entry| {
        self.allocator.free(entry.key_ptr.text);
        self.allocator.free(entry.value_ptr.glyphs);
    }
    self.shaped_cache.deinit(self.allocator);
    self.stale_shaped_keys.deinit(self.allocator);

    var wrap_iterator = self.wrap_cache.iterator();
    while (wrap_iterator.next()) |entry| {
        self.allocator.free(entry.key_ptr.text);
        self.allocator.free(entry.value_ptr.glyphs);
        self.allocator.free(entry.value_ptr.lines);
    }
    self.wrap_cache.deinit(self.allocator);
    self.stale_wrap_keys.deinit(self.allocator);

    self.glyph_cache.deinit();
}

pub fn getGlyph(self: *Face, codepoint: u21) !glyph.GlyphRecord {
    if (self.glyph_cache.get(codepoint)) |record| return record;

    const glyph_id = self.true_type.codepointGlyphIndex(codepoint);
    const horizontal_metrics = self.true_type.glyphHMetrics(glyph_id);
    const advance_em =
        @as(f32, @floatFromInt(horizontal_metrics.advance_width)) / self.units_per_em;

    var record: glyph.GlyphRecord = block: {
        const vertices = try self.true_type.glyphShape(self.allocator, glyph_id);
        defer self.allocator.free(vertices);

        const curves = try curve.decomposeVertices(
            self.allocator,
            vertices,
            self.units_per_em,
        );
        defer self.allocator.free(curves);

        break :block try self.glyph_builder.addCurves(curves);
    };
    record.advance_em = advance_em;

    try self.glyph_cache.put(codepoint, record);
    return record;
}

fn quantizePixels(value: f32) !u32 {
    if (!std.math.isFinite(value)) return error.InvalidPixelSize;
    if (value < 0) return error.InvalidPixelSize;

    const scaled = @round(value * 64);
    if (scaled >= quantized_pixel_exclusive_max) return error.InvalidPixelSize;
    return @intFromFloat(scaled);
}

fn validateTextLength(text: []const u8) !void {
    if (text.len > text_bytes_max) return error.TextTooLong;
}

/// Shape `text` as a single line at `size_px`. Result is cached for the
/// frame; slice is stable until `endFrame` evicts unused entries.
pub fn shape(self: *Face, text: []const u8, size_px: f32) !glyph.ShapedView {
    try validateTextLength(text);
    const size_quantized = try quantizePixels(size_px);
    const probe = ShapedKey{ .text = text, .size_quantized = size_quantized };

    if (self.shaped_cache.getEntryContext(probe, .{})) |entry| {
        entry.value_ptr.last_used_frame = self.current_frame;
        return .{
            .glyphs = entry.value_ptr.glyphs,
            .width = entry.value_ptr.width,
            .ascender = entry.value_ptr.ascender,
        };
    }
    if (self.shaped_cache.count() >= cache_entry_count_max) return error.TextCacheFull;

    var utf8_view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iterator = utf8_view.iterator();

    var shaped_glyphs: std.ArrayList(glyph.Shaped) = .empty;
    defer shaped_glyphs.deinit(self.allocator);

    var pen_x: f32 = 0;
    while (iterator.i < text.len) {
        const cluster: u32 = @intCast(iterator.i);
        const codepoint = iterator.nextCodepoint() orelse unreachable;

        const record = try self.getGlyph(codepoint);
        const advance_px = record.advance_em * size_px;
        try shaped_glyphs.append(self.allocator, .{
            .record = record,
            .x = pen_x,
            .advance = advance_px,
            .cluster = cluster,
        });
        pen_x += advance_px;
    }

    const glyphs = try shaped_glyphs.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(glyphs);
    const ascender = self.ascender_em * size_px;
    const text_copy = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(text_copy);

    try self.shaped_cache.putNoClobberContext(
        self.allocator,
        .{ .text = text_copy, .size_quantized = size_quantized },
        .{
            .glyphs = glyphs,
            .width = pen_x,
            .ascender = ascender,
            .last_used_frame = self.current_frame,
        },
        .{},
    );

    return .{ .glyphs = glyphs, .width = pen_x, .ascender = ascender };
}

pub fn lineHeight(self: *Face, size_px: f32) !f32 {
    _ = try quantizePixels(size_px);
    return self.line_height_em * size_px;
}

const WrapBuffer = struct {
    face: *Face,
    source_glyphs: []const glyph.Shaped,
    glyphs: []glyph.Shaped,
    lines: std.ArrayList(glyph.Line),
    line_height: f32,
    glyph_count: usize,
    width: f32,

    fn deinit(self: *WrapBuffer) void {
        self.lines.deinit(self.face.allocator);
    }

    fn appendLine(
        self: *WrapBuffer,
        glyph_start: usize,
        glyph_end: usize,
        byte_start: u32,
        byte_end: u32,
    ) !void {
        std.debug.assert(glyph_start <= glyph_end);
        std.debug.assert(glyph_end <= self.source_glyphs.len);
        std.debug.assert(byte_start <= byte_end);

        const target_start = self.glyph_count;
        const glyph_count = glyph_end - glyph_start;
        const x_start = if (glyph_count > 0) self.source_glyphs[glyph_start].x else 0;
        for (self.source_glyphs[glyph_start..glyph_end], 0..) |source, index| {
            self.glyphs[target_start + index] = .{
                .record = source.record,
                .x = source.x - x_start,
                .advance = source.advance,
                .cluster = source.cluster - byte_start,
            };
        }
        self.glyph_count += glyph_count;

        const width = lineWidth(self.source_glyphs, glyph_start, glyph_end);
        const y = @as(f32, @floatFromInt(self.lines.items.len)) * self.line_height;
        try self.lines.append(self.face.allocator, .{
            .glyphs = self.glyphs[target_start..self.glyph_count],
            .byte_start = byte_start,
            .byte_end = byte_end,
            .width = width,
            .y = y,
        });
        self.width = @max(self.width, width);
    }
};

const OwnedWrap = struct {
    glyphs: []glyph.Shaped,
    lines: []glyph.Line,
    width: f32,
    height: f32,
};

const CacheWrapOptions = struct {
    key: WrapKey,
    owned: OwnedWrap,
    ascender: f32,
    line_height: f32,
};

const WrapCursor = struct {
    line_glyph_start: usize = 0,
    line_byte_start: u32 = 0,
    last_break: ?usize = null,
    glyph_index: usize = 0,
};

fn lineWidth(shaped_glyphs: []const glyph.Shaped, start: usize, end: usize) f32 {
    std.debug.assert(start <= end);
    std.debug.assert(end <= shaped_glyphs.len);
    if (start == end) return 0;

    const first = shaped_glyphs[start];
    const last = shaped_glyphs[end - 1];
    return last.x + last.advance - first.x;
}

fn glyphByte(text: []const u8, shaped: glyph.Shaped) u8 {
    std.debug.assert(shaped.cluster < text.len);
    return text[shaped.cluster];
}

fn isBlank(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn skipBlankGlyphs(
    text: []const u8,
    shaped_glyphs: []const glyph.Shaped,
    start: usize,
) usize {
    var end = start;
    while (end < shaped_glyphs.len) : (end += 1) {
        if (!isBlank(glyphByte(text, shaped_glyphs[end]))) break;
    }
    return end;
}

fn buildWrappedLinesHardBreak(
    buffer: *WrapBuffer,
    text: []const u8,
    cursor: *WrapCursor,
    shaped: glyph.Shaped,
) !void {
    try buffer.appendLine(
        cursor.line_glyph_start,
        cursor.glyph_index,
        cursor.line_byte_start,
        shaped.cluster,
    );
    cursor.glyph_index += 1;
    cursor.line_glyph_start = cursor.glyph_index;
    cursor.line_byte_start =
        shaped.cluster + @as(u32, @intCast(charLen(text, shaped.cluster)));
    cursor.last_break = null;
}

fn buildWrappedLinesBlank(
    buffer: *const WrapBuffer,
    text: []const u8,
    cursor: *WrapCursor,
) void {
    if (cursor.glyph_index > cursor.line_glyph_start) {
        const previous = buffer.source_glyphs[cursor.glyph_index - 1];
        if (!isBlank(glyphByte(text, previous))) cursor.last_break = cursor.glyph_index;
    }
    cursor.glyph_index += 1;
}

fn buildWrappedLinesOverflow(
    buffer: *WrapBuffer,
    text: []const u8,
    cursor: *WrapCursor,
    shaped: glyph.Shaped,
) !bool {
    if (cursor.last_break) |break_index| {
        const break_byte = buffer.source_glyphs[break_index].cluster;
        try buffer.appendLine(
            cursor.line_glyph_start,
            break_index,
            cursor.line_byte_start,
            break_byte,
        );
        cursor.line_glyph_start = skipBlankGlyphs(text, buffer.source_glyphs, break_index);
        std.debug.assert(cursor.line_glyph_start <= cursor.glyph_index);
        cursor.line_byte_start = buffer.source_glyphs[cursor.line_glyph_start].cluster;
        cursor.last_break = null;
        return true;
    }
    if (cursor.glyph_index > cursor.line_glyph_start) {
        try buffer.appendLine(
            cursor.line_glyph_start,
            cursor.glyph_index,
            cursor.line_byte_start,
            shaped.cluster,
        );
        cursor.line_glyph_start = cursor.glyph_index;
        cursor.line_byte_start = shaped.cluster;
    }
    return false;
}

fn buildWrappedLines(buffer: *WrapBuffer, text: []const u8, wrap_px: f32) !void {
    var cursor = WrapCursor{};

    while (cursor.glyph_index < buffer.source_glyphs.len) {
        const shaped = buffer.source_glyphs[cursor.glyph_index];
        const byte = glyphByte(text, shaped);
        if (byte == '\n') {
            try buildWrappedLinesHardBreak(buffer, text, &cursor, shaped);
            continue;
        }
        if (isBlank(byte)) {
            buildWrappedLinesBlank(buffer, text, &cursor);
            continue;
        }
        if (wrap_px > 0) {
            const width = lineWidth(
                buffer.source_glyphs,
                cursor.line_glyph_start,
                cursor.glyph_index + 1,
            );
            if (width > wrap_px) {
                if (try buildWrappedLinesOverflow(buffer, text, &cursor, shaped)) continue;
            }
        }
        cursor.glyph_index += 1;
    }

    try buffer.appendLine(
        cursor.line_glyph_start,
        buffer.source_glyphs.len,
        cursor.line_byte_start,
        @intCast(text.len),
    );
}

fn cacheWrapped(
    self: *Face,
    text: []const u8,
    options: CacheWrapOptions,
) !glyph.ShapedWrappedView {
    if (self.wrap_cache.count() >= cache_entry_count_max) return error.TextCacheFull;

    const text_copy = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(text_copy);

    try self.wrap_cache.putNoClobberContext(
        self.allocator,
        .{
            .text = text_copy,
            .size_quantized = options.key.size_quantized,
            .wrap_quantized = options.key.wrap_quantized,
        },
        .{
            .glyphs = options.owned.glyphs,
            .lines = options.owned.lines,
            .width = options.owned.width,
            .height = options.owned.height,
            .ascender = options.ascender,
            .line_height = options.line_height,
            .last_used_frame = self.current_frame,
        },
        .{},
    );

    return .{
        .lines = options.owned.lines,
        .width = options.owned.width,
        .height = options.owned.height,
        .ascender = options.ascender,
        .line_height = options.line_height,
    };
}

fn cacheEmptyWrapped(
    self: *Face,
    text: []const u8,
    key: WrapKey,
    ascender: f32,
    line_height: f32,
) !glyph.ShapedWrappedView {
    const shaped_glyphs = try self.allocator.alloc(glyph.Shaped, 0);
    errdefer self.allocator.free(shaped_glyphs);
    const lines = try self.allocator.alloc(glyph.Line, 0);
    errdefer self.allocator.free(lines);

    return self.cacheWrapped(text, .{
        .key = key,
        .owned = .{
            .glyphs = shaped_glyphs,
            .lines = lines,
            .width = 0,
            .height = line_height,
        },
        .ascender = ascender,
        .line_height = line_height,
    });
}

/// Shape `text` with greedy word-wrap at `wrap_px`. When `wrap_px <= 0`,
/// behaves like a single line per hard `\n` break only. Result is cached
/// per (text, size, wrap) for the frame; slices are stable until eviction.
pub fn shapeWrapped(
    self: *Face,
    text: []const u8,
    size_px: f32,
    wrap_px: f32,
) !glyph.ShapedWrappedView {
    try validateTextLength(text);
    const size_quantized = try quantizePixels(size_px);
    const wrap_quantized = if (wrap_px <= 0) 0 else try quantizePixels(wrap_px);
    const probe = WrapKey{
        .text = text,
        .size_quantized = size_quantized,
        .wrap_quantized = wrap_quantized,
    };
    const line_height = self.line_height_em * size_px;
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
        return self.cacheEmptyWrapped(text, probe, ascender, line_height);
    }

    const shaped = try self.shape(text, size_px);
    const wrapped_glyphs = try self.allocator.alloc(glyph.Shaped, shaped.glyphs.len);
    errdefer self.allocator.free(wrapped_glyphs);
    var buffer = WrapBuffer{
        .face = self,
        .source_glyphs = shaped.glyphs,
        .glyphs = wrapped_glyphs,
        .lines = .empty,
        .line_height = line_height,
        .glyph_count = 0,
        .width = 0,
    };
    defer buffer.deinit();

    try buildWrappedLines(&buffer, text, wrap_px);
    const lines = try buffer.lines.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(lines);
    const height = @as(f32, @floatFromInt(lines.len)) * line_height;

    return self.cacheWrapped(text, .{
        .key = probe,
        .owned = .{
            .glyphs = wrapped_glyphs,
            .lines = lines,
            .width = buffer.width,
            .height = height,
        },
        .ascender = ascender,
        .line_height = line_height,
    });
}

fn charLen(text: []const u8, byte: u32) usize {
    if (byte < text.len) {
        return std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
    }
    return 0;
}

pub fn measure(self: *Face, text: []const u8, size_px: f32) !glyph.TextMetrics {
    try validateTextLength(text);
    const line_height = try self.lineHeight(size_px);

    var max_line_width: f32 = 0;
    var line_count: u32 = 1;

    var line_start: usize = 0;
    for (text, 0..) |byte, byte_index| {
        if (byte == '\n') {
            const line = text[line_start..byte_index];
            if (line.len > 0) {
                const shaped = try self.shape(line, size_px);
                max_line_width = @max(max_line_width, shaped.width);
            }
            line_count += 1;
            line_start = byte_index + 1;
        }
    }
    const final_line = text[line_start..];
    if (final_line.len > 0) {
        const shaped = try self.shape(final_line, size_px);
        max_line_width = @max(max_line_width, shaped.width);
    }

    return .{
        .width = max_line_width,
        .height = line_height * @as(f32, @floatFromInt(line_count)),
        .line_count = line_count,
    };
}

fn evictShaped(self: *Face) void {
    self.stale_shaped_keys.clearRetainingCapacity();
    var iterator = self.shaped_cache.iterator();
    while (iterator.next()) |entry| {
        std.debug.assert(self.stale_shaped_keys.items.len <= cache_evictions_per_frame_max);
        if (self.stale_shaped_keys.items.len == cache_evictions_per_frame_max) break;

        const age = self.current_frame -% entry.value_ptr.last_used_frame;
        if (age > cache_evict_age_frames) {
            self.stale_shaped_keys.appendAssumeCapacity(entry.key_ptr.*);
        }
    }

    for (self.stale_shaped_keys.items) |key| {
        if (self.shaped_cache.fetchRemoveContext(key, .{})) |entry| {
            self.allocator.free(entry.key.text);
            self.allocator.free(entry.value.glyphs);
        }
    }
}

fn evictWrapped(self: *Face) void {
    self.stale_wrap_keys.clearRetainingCapacity();
    var iterator = self.wrap_cache.iterator();
    while (iterator.next()) |entry| {
        std.debug.assert(self.stale_wrap_keys.items.len <= cache_evictions_per_frame_max);
        if (self.stale_wrap_keys.items.len == cache_evictions_per_frame_max) break;

        const age = self.current_frame -% entry.value_ptr.last_used_frame;
        if (age > cache_evict_age_frames) {
            self.stale_wrap_keys.appendAssumeCapacity(entry.key_ptr.*);
        }
    }

    for (self.stale_wrap_keys.items) |key| {
        if (self.wrap_cache.fetchRemoveContext(key, .{})) |entry| {
            self.allocator.free(entry.key.text);
            self.allocator.free(entry.value.glyphs);
            self.allocator.free(entry.value.lines);
        }
    }
}

/// Advance the frame and evict a bounded batch of shaped text unused for two frames.
pub fn endFrame(self: *Face) void {
    std.debug.assert(self.shaped_cache.count() <= cache_entry_count_max);
    std.debug.assert(self.wrap_cache.count() <= cache_entry_count_max);
    self.evictShaped();
    self.evictWrapped();
    self.current_frame +%= 1;
}
