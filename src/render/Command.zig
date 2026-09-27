const types = @import("render_types");
const math = @import("math");
const Clip = @import("Clip.zig");

/// Erased so `ui` builds draw lists without a GPU backend; the renderer casts back.
pub const Extension = enum(u64) { knots = 0x6b6e6f7473, _ };

pub const TextureHandle = struct {
    extension: Extension,
    pointer: *const anyopaque,
};

/// `draw_context` is the renderer's own context (`renderer.gpu.DrawContext` for
/// Knots'), erased like `TextureHandle` and restored before the call.
pub const CustomDrawCallback = *const fn (
    user_data: ?*anyopaque,
    draw_context: *anyopaque,
) anyerror!void;

/// Backend-neutral callback descriptor. The extension identifies the expected
/// context type; user_data is borrowed through rendering, never owned by the UI.
pub const PaintCallback = struct {
    extension: Extension,
    callback: CustomDrawCallback,
    user_data: ?*anyopaque,

    pub fn validate(self: *const PaintCallback) void {
        const std = @import("std");
        std.debug.assert(@backingInt(self.extension) > 0);
        std.debug.assert(@intFromPtr(self.callback) > 0);
    }
};

pub const TextureSource = union(enum) {
    atlas,
    texture: TextureHandle,
    pixels: Pixels,

    pub const Pixels = struct {
        key: u64,
        data: []const u8,
        width: u32,
        height: u32,
        format: types.Texture.Format,
        bytes_per_row: ?u32,
        version: u64,
        force_upload: bool,
    };
};

pub const Command = struct {
    clip: Clip.State,
    payload: Payload,

    pub const Kind = enum {
        vertex,
        instance,
        text,
        custom_draw,
        backdrop,
    };

    pub const Payload = union(Kind) {
        vertex: Indexed,
        instance: Instanced,
        text: Text,
        custom_draw: CustomDraw,
        backdrop: Backdrop,
    };

    pub const Indexed = struct {
        texture: TextureSource,
        offset: u32,
        count: u32,
    };

    pub const Instanced = struct {
        texture: TextureSource,
        offset: u32,
        count: u32,
    };

    pub const Text = struct {
        offset: u32,
        count: u32,
    };

    pub const CustomDraw = struct {
        paint: PaintCallback,
        bounds: math.Rect,
    };

    /// Filters what earlier commands painted inside a rounded rect. A barrier:
    /// renderers must not reorder or batch draws across it. Commands sharing a
    /// `group` sample one snapshot, taken at the group's first command in packet
    /// order, so later members do not see each other or anything drawn between.
    pub const Backdrop = struct {
        bounds: math.Rect,
        corner_radius: [4]f32,
        material: types.Material,
        /// Below `groups_max`.
        group: u32,

        /// Each group costs a pass break and a blur.
        pub const groups_max = 64;
    };
};
