const std = @import("std");
const GlyphBuilder = @import("GlyphBuilder.zig");
const Face = @import("Face.zig");

pub const FontKey = struct { []const u8, []const u8 };

const KeyedFace = struct { key: []const u8, face: Face };

allocator: std.mem.Allocator,
glyph_builder: *GlyphBuilder,
faces: std.ArrayList(KeyedFace),

const Font = @This();

pub fn init(allocator: std.mem.Allocator, fonts: []const FontKey) !Font {
    const glyph_builder = try allocator.create(GlyphBuilder);
    errdefer allocator.destroy(glyph_builder);
    glyph_builder.* = try GlyphBuilder.init(allocator);
    errdefer glyph_builder.deinit();

    var faces: std.ArrayList(KeyedFace) = try .initCapacity(allocator, fonts.len);
    errdefer {
        for (faces.items) |*kf| kf.face.deinit();
        faces.deinit(allocator);
    }

    for (fonts) |font| faces.appendAssumeCapacity(.{
        .key = font.@"0",
        .face = try Face.init(allocator, font.@"1", glyph_builder),
    });

    return .{
        .allocator = allocator,
        .glyph_builder = glyph_builder,
        .faces = faces,
    };
}

pub fn addFace(self: *Font, key: []const u8, data: []const u8) !void {
    var face = try Face.init(self.allocator, data, self.glyph_builder);
    errdefer face.deinit();
    try self.faces.append(self.allocator, .{ .key = key, .face = face });
}

pub fn getFace(self: *Font, key: ?[]const u8) !*Face {
    const k = key orelse return &self.faces.items[0].face;
    for (self.faces.items) |*kf|
        if (std.mem.eql(u8, k, kf.key)) return &kf.face;
    return error.UnknownFont;
}

pub fn endFrame(self: *Font) void {
    for (self.faces.items) |*kf| kf.face.endFrame();
}

pub fn deinit(self: *Font) void {
    for (self.faces.items) |*kf| kf.face.deinit();
    self.faces.deinit(self.allocator);
    self.glyph_builder.deinit();
    self.allocator.destroy(self.glyph_builder);
}
