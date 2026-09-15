const Frame = @import("../Frame.zig");
const Key = @import("ui").Key;
const Element = @import("layout").Element;
const gpu = @import("gpu");
const render = @import("render");
const renderer = @import("renderer");

/// `data` is borrowed and uploaded at draw time, after the frame callback
/// returns, so it must stay valid until the next frame begins.
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

/// Both variants are desktop only; an embedded `View` reports `ImageUnsupported`.
pub const Source = union(enum) {
    texture: *const renderer.Texture,
    pixels: Pixels,
};

pub const SamplingMode = enum {
    alpha,
    @"opaque",
};

source: Source,
width: Element.sizing.Axis = .grow(),
height: Element.sizing.Axis = .grow(),
position: Element.Position = .static,
tint: [4]f32 = .{ 1, 1, 1, 1 },
sampling_mode: SamplingMode = .alpha,
key: Key,

const Image = @This();

pub fn open(self: *const Image, frame: *Frame) !Element.Id {
    const source: render.DrawList.TextureSource = switch (self.source) {
        .texture => |value| .{ .texture = @ptrCast(value) },
        .pixels => |p| .{ .pixels = .{
            .key = self.key.hash(),
            .data = p.data,
            .width = p.width,
            .height = p.height,
            .format = p.format,
            .bytes_per_row = p.bytes_per_row,
            .version = p.version,
            .force_upload = p.upload_policy == .always,
        } },
    };

    return try frame.ui().open(self.key, .{
        .width = self.width,
        .height = self.height,
        .position = self.position,
        .overflow = .hidden,
    }, .{ .image = .{
        .source = source,
        .tint = self.tint,
        .@"opaque" = self.sampling_mode == .@"opaque",
    } });
}

pub fn close(_: *const Image, frame: *Frame) !void {
    frame.ui().close();
}
