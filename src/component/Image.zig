const App = @import("knots").App;
const Key = @import("ui").Key;
const Element = @import("layout").Element;
const gpu = @import("gpu");

pub const Pixels = struct {
    pub const UploadPolicy = enum {
        /// Upload every frame. This is the safe default for mutable slices.
        always,
        /// Upload only when metadata or `version` changes.
        versioned,
    };

    data: []const u8,
    width: u32,
    height: u32,
    format: gpu.Texture.Format = .rgba8,
    bytes_per_row: ?u32 = null,
    upload_policy: UploadPolicy = .always,
    version: u64 = 0,
};

pub const Source = union(enum) {
    texture: u32,
    pixels: Pixels,
};

source: Source,
width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .grow(),
position: Element.Position = .static,
tint: [4]f32 = .{ 1, 1, 1, 1 },
key: Key,

const Image = @This();

pub fn open(self: *const Image, app: *App) !Element.Id {
    const texture_id = switch (self.source) {
        .texture => |id| id,
        .pixels => |p| try app.renderer.textureFromPixels(
            self.key.hash(),
            p.data,
            p.width,
            p.height,
            p.format,
            p.bytes_per_row,
            p.version,
            p.upload_policy == .always,
        ),
    };

    return try app.ui.open(self.key, .{
        .width = self.width,
        .height = self.height,
        .position = self.position,
        .overflow = .hidden,
    }, .{ .image = .{
        .texture_id = texture_id,
        .tint = self.tint,
    } });
}

pub fn close(_: *const Image, app: *App) !void {
    app.ui.close();
}
