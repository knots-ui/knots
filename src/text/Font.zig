const std = @import("std");
const ft = @import("freetype").c;
const Atlas = @import("Atlas.zig");
const Face = @import("Face.zig");

pub const FontKey = struct { []const u8, []const u8 };

const KeyedFace = struct { key: []const u8, face: Face };

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
        for (faces.items) |*kf| kf.face.deinit();
        faces.deinit(allocator);
    }

    for (fonts) |font| faces.appendAssumeCapacity(.{
        .key = font.@"0",
        .face = try Face.init(allocator, ft_lib, font.@"1", atlas),
    });

    return .{
        .allocator = allocator,
        .ft_lib = ft_lib,
        .atlas = atlas,
        .faces = faces,
    };
}

pub fn addFace(self: *Font, key: []const u8, data: []const u8) !void {
    var face = try Face.init(self.allocator, self.ft_lib, data, self.atlas);
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
    self.atlas.deinit();
    self.allocator.destroy(self.atlas);
    _ = ft.FT_Done_FreeType(self.ft_lib);
}
