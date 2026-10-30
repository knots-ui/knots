//! HarfBuzz, built from source by `zig build`, as the oracle the shaper is compared against.
//! Shaping mirrors `hb-shape --font-funcs=ot --utf8-clusters --unsafe-to-concat` under `LC_ALL=C`:
//! positions in font units, clusters as byte offsets.

const std = @import("std");
const manifest = @import("manifest.zig");

pub const Font = opaque {};
const Blob = opaque {};
const Face = opaque {};
const Buffer = opaque {};
const Language = opaque {};

const Feature = extern struct { tag: u32, value: u32, start: c_uint, end: c_uint };
const GlyphInfo = extern struct { codepoint: u32, mask: u32, cluster: u32, var1: u32, var2: u32 };
const GlyphPosition = extern struct { x_advance: i32, y_advance: i32, x_offset: i32, y_offset: i32, var1: u32 };
const MessageFn = *const fn (*Buffer, *Font, [*:0]const u8, ?*anyopaque) callconv(.c) c_int;

extern fn hb_version_string() [*:0]const u8;
extern fn hb_blob_create(data: [*]const u8, length: c_uint, mode: c_int, user_data: ?*anyopaque, destroy: ?*const anyopaque) *Blob;
extern fn hb_blob_destroy(blob: *Blob) void;
extern fn hb_face_create(blob: *Blob, index: c_uint) *Face;
extern fn hb_face_destroy(face: *Face) void;
extern fn hb_font_create(face: *Face) *Font;
extern fn hb_font_destroy(font: *Font) void;
extern fn hb_buffer_create() *Buffer;
extern fn hb_buffer_destroy(buffer: *Buffer) void;
extern fn hb_buffer_clear_contents(buffer: *Buffer) void;
extern fn hb_buffer_add_utf8(buffer: *Buffer, text: [*]const u8, text_length: c_int, item_offset: c_uint, item_length: c_int) void;
extern fn hb_buffer_set_script(buffer: *Buffer, script: u32) void;
extern fn hb_buffer_set_language(buffer: *Buffer, language: ?*const Language) void;
extern fn hb_buffer_set_flags(buffer: *Buffer, flags: c_uint) void;
extern fn hb_buffer_guess_segment_properties(buffer: *Buffer) void;
extern fn hb_buffer_set_message_func(buffer: *Buffer, func: ?MessageFn, user_data: ?*anyopaque, destroy: ?*const anyopaque) void;
extern fn hb_buffer_get_glyph_infos(buffer: *Buffer, length: *c_uint) [*]GlyphInfo;
extern fn hb_buffer_get_glyph_positions(buffer: *Buffer, length: *c_uint) [*]GlyphPosition;
extern fn hb_script_from_string(str: [*]const u8, len: c_int) u32;
extern fn hb_language_from_string(str: [*]const u8, len: c_int) ?*const Language;
extern fn hb_feature_from_string(str: [*]const u8, len: c_int, feature: *Feature) c_int;
extern fn hb_shape(font: *Font, buffer: *Buffer, features: [*]const Feature, num_features: c_uint) void;

const memory_mode_readonly = 1;
const flag_produce_unsafe_to_concat = 0x40;
const glyph_flags_defined = 0x7;

pub fn version() []const u8 {
    return std.mem.span(hb_version_string());
}

/// `data` must outlive the font.
pub fn createFont(data: []const u8) *Font {
    const blob = hb_blob_create(data.ptr, @intCast(data.len), memory_mode_readonly, null, null);
    defer hb_blob_destroy(blob);
    const face = hb_face_create(blob, 0);
    defer hb_face_destroy(face);
    return hb_font_create(face);
}

pub fn destroyFont(font: *Font) void {
    hb_font_destroy(font);
}

pub const Oracle = struct {
    buffer: *Buffer,

    pub fn init() Oracle {
        return .{ .buffer = hb_buffer_create() };
    }

    pub fn deinit(self: *Oracle) void {
        hb_buffer_destroy(self.buffer);
    }

    /// `features` is a comma-separated list in HarfBuzz syntax.
    pub fn shape(self: *Oracle, arena: std.mem.Allocator, font: *Font, script: []const u8, features: []const u8, text: []const u8) ![]manifest.Glyph {
        try self.run(arena, font, script, features, text);
        var count: c_uint = 0;
        const infos = hb_buffer_get_glyph_infos(self.buffer, &count);
        const positions = hb_buffer_get_glyph_positions(self.buffer, &count);
        const glyphs = try arena.alloc(manifest.Glyph, count);
        for (glyphs, infos[0..count], positions[0..count]) |*glyph, info, position| glyph.* = .{
            .g = info.codepoint,
            .cl = info.cluster,
            .dx = position.x_offset,
            .dy = position.y_offset,
            .ax = position.x_advance,
            .ay = position.y_advance,
            .fl = info.mask & glyph_flags_defined,
        };
        return glyphs;
    }

    pub const Lookups = struct { gsub: []const u16, gpos: []const u16 };

    /// The GSUB and GPOS lookups HarfBuzz's plan applies, in order, traced while shaping "a".
    pub fn lookups(self: *Oracle, arena: std.mem.Allocator, font: *Font, script: []const u8, features: []const u8) !Lookups {
        var trace: Trace = .{ .arena = arena };
        hb_buffer_set_message_func(self.buffer, Trace.message, &trace, null);
        defer hb_buffer_set_message_func(self.buffer, null, null, null);
        try self.run(arena, font, script, features, "a");
        if (trace.failed) return error.OutOfMemory;
        return .{ .gsub = trace.tables[0].items, .gpos = trace.tables[1].items };
    }

    fn run(self: *Oracle, arena: std.mem.Allocator, font: *Font, script: []const u8, features: []const u8, text: []const u8) !void {
        var parsed: std.ArrayList(Feature) = .empty;
        var parts = std.mem.splitScalar(u8, features, ',');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            var feature: Feature = undefined;
            if (hb_feature_from_string(part.ptr, @intCast(part.len), &feature) == 0) return error.InvalidFeature;
            try parsed.append(arena, feature);
        }
        hb_buffer_clear_contents(self.buffer);
        hb_buffer_set_script(self.buffer, hb_script_from_string(script.ptr, @intCast(script.len)));
        hb_buffer_set_language(self.buffer, hb_language_from_string("c", 1));
        hb_buffer_set_flags(self.buffer, flag_produce_unsafe_to_concat);
        hb_buffer_add_utf8(self.buffer, text.ptr, @intCast(text.len), 0, @intCast(text.len));
        hb_buffer_guess_segment_properties(self.buffer);
        hb_shape(font, self.buffer, parsed.items.ptr, @intCast(parsed.items.len));
    }
};

const Trace = struct {
    arena: std.mem.Allocator,
    /// GSUB, GPOS.
    tables: [2]std.ArrayList(u16) = .{ .empty, .empty },
    table: ?usize = null,
    failed: bool = false,

    fn message(_: *Buffer, _: *Font, text: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) c_int {
        const self: *Trace = @ptrCast(@alignCast(user_data.?));
        const line = std.mem.span(text);
        if (std.mem.startsWith(u8, line, "start table GSUB")) self.table = 0;
        if (std.mem.startsWith(u8, line, "start table GPOS")) self.table = 1;
        if (std.mem.startsWith(u8, line, "end table")) self.table = null;
        const prefix = "start lookup ";
        const table = self.table orelse return 1;
        if (!std.mem.startsWith(u8, line, prefix)) return 1;
        const rest = line[prefix.len..];
        const end = std.mem.findScalar(u8, rest, ' ') orelse rest.len;
        const index = std.fmt.parseInt(u16, rest[0..end], 10) catch return 1;
        self.tables[table].append(self.arena, index) catch {
            self.failed = true;
        };
        return 1;
    }
};
