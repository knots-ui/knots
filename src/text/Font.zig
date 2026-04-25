const std = @import("std");
const ft = @import("freetype").c;
const Atlas = @import("Atlas.zig");
const Face = @import("Face.zig");

pub const FontKey = struct { []const u8, []const u8 };

const KeyedFace = struct { []const u8, Face };

allocator: std.mem.Allocator,
ft_lib: ft.FT_Library,
atlas: *Atlas,
faces: std.ArrayList(KeyedFace),

const Font = @This();

pub fn init(allocator: std.mem.Allocator, fonts: []const FontKey) !Font {
    var ft_lib: ft.FT_Library = undefined;
    if (ft.FT_Init_FreeType(&ft_lib) != 0) return error.FreeTypeInitFailed;

    const atlas = try allocator.create(Atlas);
    errdefer allocator.destroy(atlas);
    atlas.* = try Atlas.init(allocator, 1024, 1024);
    errdefer atlas.deinit();

    var faces: std.ArrayList(KeyedFace) = try .initCapacity(allocator, fonts.len);
    errdefer {
        for (faces.items) |*face| face.@"1".deinit();
        faces.deinit(allocator);
    }

    for (fonts) |font| faces.appendAssumeCapacity(.{ font.@"0", try Face.init(allocator, ft_lib, font.@"1", atlas) });

    return .{
        .allocator = allocator,
        .ft_lib = ft_lib,
        .atlas = atlas,
        .faces = faces,
    };
}

pub fn addFace(self: *Font, key: []const u8, data: []const u8) !void {
    try self.faces.append(self.allocator, .{ key, try .init(self.allocator, self.ft_lib, data, self.atlas) });
}

pub fn getFace(self: *Font, key: ?[]const u8) !*Face {
    const k = key orelse return &self.faces.items[0].@"1";
    for (self.faces.items) |*face|
        if (k.ptr == face.@"0".ptr and k.len == face.@"0".len) return &face.@"1";
    for (self.faces.items) |*face|
        if (std.mem.eql(u8, k, face.@"0")) return &face.@"1";
    return error.UnknownFont;
}

pub fn endFrame(self: *Font) void {
    for (self.faces.items) |*face| face.@"1".endFrame();
}

pub fn deinit(self: *Font) void {
    for (self.faces.items) |*face| {
        face.@"1".deinit();
    }
    self.faces.deinit(self.allocator);
    self.atlas.deinit();
    self.allocator.destroy(self.atlas);
    _ = ft.FT_Done_FreeType(self.ft_lib);
}
