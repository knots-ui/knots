const ui_mod = @import("../root.zig");
const Frame = ui_mod.Frame;
const Key = ui_mod.Key;
const Style = ui_mod.Style;
const Element = @import("layout").Element;
const types = @import("render_types");
const render = @import("render");

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
    format: types.Texture.Format = .rgba8,
    bytes_per_row: ?u32 = null,
    upload_policy: UploadPolicy = .always,
    version: u64 = 0,
};

/// Pixel data is portable; texture handles belong to their declared renderer extension.
pub const Source = union(enum) {
    texture: render.TextureHandle,
    pixels: Pixels,
};

pub const SamplingMode = enum {
    alpha,
    @"opaque",
};

source: Source,
sampling_mode: SamplingMode = .alpha,
key: Key,
/// `foreground` tints the image.
style: *const Style = &.{},

pub const base = struct {
    /// White foreground so the image does not inherit the text color as tint.
    pub const root: Style = .{
        .width = .grow(),
        .height = .grow(),
        .overflow = .hidden,
        .foreground = .{ .color = .{ .value = .{ 1, 1, 1, 1 } } },
    };
};

const Image = @This();

pub fn open(self: *const Image, frame: *Frame) !Element.Id {
    const source: render.DrawList.TextureSource = switch (self.source) {
        .texture => |value| .{ .texture = value },
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

    const ui = frame.ui();
    const resolved = ui.resolveStyle(self.key.hash(), .{ .base = &base.root, .user = self.style }, .{}, null);
    return try ui.openWith(self.key, resolved.element(.{}), .{ .image = .{
        .source = source,
        .tint = resolved.content.foreground,
        .@"opaque" = self.sampling_mode == .@"opaque",
    } }, .{ .content = resolved.content });
}

pub fn close(_: *const Image, frame: *Frame) !void {
    frame.ui().close();
}
