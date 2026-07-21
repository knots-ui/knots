const std = @import("std");
const GlyphBuilder = @import("GlyphBuilder.zig");
const Face = @import("Face.zig");

allocator: std.mem.Allocator,
glyph_builder: *GlyphBuilder,
faces: std.ArrayList(FaceEntry),

const Font = @This();
// A bounded font set keeps duplicate validation and frame maintenance predictable.
const font_count_max: u32 = 256;

pub const FontSource = struct {
    name: []const u8,
    data: []const u8,
};

const FaceEntry = struct {
    name: []const u8,
    face: Face,
};

/// The names and font data must remain valid until `deinit`.
pub fn init(allocator: std.mem.Allocator, sources: []const FontSource) !Font {
    if (sources.len == 0) return error.EmptyFontSet;
    try validateFontCount(sources.len);
    for (sources, 0..) |source, source_index| {
        for (sources[0..source_index]) |existing| {
            if (std.mem.eql(u8, source.name, existing.name)) return error.DuplicateFont;
        }
    }

    const glyph_builder = try allocator.create(GlyphBuilder);
    errdefer allocator.destroy(glyph_builder);
    glyph_builder.* = try GlyphBuilder.init(allocator);
    errdefer glyph_builder.deinit();

    var faces: std.ArrayList(FaceEntry) = try .initCapacity(allocator, sources.len);
    errdefer {
        for (faces.items) |*entry| entry.face.deinit();
        faces.deinit(allocator);
    }

    for (sources) |source| {
        faces.appendAssumeCapacity(.{
            .name = source.name,
            .face = try Face.init(allocator, source.data, glyph_builder),
        });
    }

    return .{
        .allocator = allocator,
        .glyph_builder = glyph_builder,
        .faces = faces,
    };
}

/// The name and font data must remain valid until `deinit`.
pub fn addFace(self: *Font, name: []const u8, data: []const u8) !void {
    std.debug.assert(self.faces.items.len <= font_count_max);
    for (self.faces.items) |*entry| {
        if (std.mem.eql(u8, name, entry.name)) return error.DuplicateFont;
    }
    try validateFontCount(self.faces.items.len + 1);

    var face = try Face.init(self.allocator, data, self.glyph_builder);
    errdefer face.deinit();
    try self.faces.append(self.allocator, .{ .name = name, .face = face });
    std.debug.assert(self.faces.items.len <= font_count_max);
}

pub fn getFace(self: *Font, name: ?[]const u8) !*Face {
    const requested_name = name orelse return &self.faces.items[0].face;
    for (self.faces.items) |*entry| {
        if (std.mem.eql(u8, requested_name, entry.name)) return &entry.face;
    }
    return error.UnknownFont;
}

pub fn endFrame(self: *Font) void {
    for (self.faces.items) |*entry| entry.face.endFrame();
}

pub fn deinit(self: *Font) void {
    std.debug.assert(self.faces.items.len <= font_count_max);
    for (self.faces.items) |*entry| entry.face.deinit();
    self.faces.deinit(self.allocator);
    self.glyph_builder.deinit();
    self.allocator.destroy(self.glyph_builder);
}

fn validateFontCount(count: usize) !void {
    if (count > font_count_max) return error.TooManyFonts;
}

test "font count accepts the boundary and rejects one face more" {
    try validateFontCount(font_count_max);
    try std.testing.expectError(
        error.TooManyFonts,
        validateFontCount(font_count_max + 1),
    );
}
