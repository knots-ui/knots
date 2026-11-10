//! Vertex layouts, resource bindings, texture formats, and uniform contracts.

const std = @import("std");
const Vertex = @import("Vertex.zig");
const Instance = @import("Instance.zig");
const SlugInstance = @import("SlugInstance.zig");

/// All packet geometry uses logical pixels with the origin at the top-left.
/// Commands are triangle lists, use `u32` indices, disable culling, and must be
/// encoded in packet order. A command's scissor is also expressed in logical
/// pixels and must be intersected with the render target after content scaling.
///
/// A `backdrop` command filters pixels already painted inside its rounded rect
/// and is an ordering barrier. Renderers that cannot sample their target may
/// skip it; the element's own surface is emitted separately.
pub const geometry = struct {
    pub const text_quad_indices = [6]u32{ 0, 1, 2, 0, 2, 3 };
    pub const front_face: FrontFace = .counter_clockwise;
    pub const culling = false;
};

pub const FrontFace = enum { counter_clockwise, clockwise };

/// Resource-group and binding numbers shared by the bundled shaders.
pub const bindings = struct {
    pub const primitives_uniform_group: u32 = 0;
    pub const primitives_uniform: u32 = 0;
    pub const primitives_texture_group: u32 = 1;
    pub const primitives_texture: u32 = 0;
    pub const primitives_sampler: u32 = 1;
    pub const clip_group: u32 = 2;
    pub const clip_nodes: u32 = 0;

    pub const text_uniform_group: u32 = 0;
    pub const text_uniform: u32 = 0;
    /// Read-only storage: the slot table (vertex stage) and the glyph words (fragment stage).
    pub const glyph_atlas_group: u32 = 1;
    pub const glyph_table: u32 = 0;
    pub const glyph_words: u32 = 1;
};

/// The primitive uniform is the logical viewport width and height in pixels.
pub const PrimitiveUniform = [2]f32;

/// Text transform and logical/physical viewport extents.
pub const TextUniform = extern struct {
    mvp_row0: [4]f32,
    mvp_row1: [4]f32,
    mvp_row2: [4]f32,
    mvp_row3: [4]f32,
    viewport: [4]f32,
};

pub const formats = struct {
    pub const offscreen_color: @import("Command.zig").PixelFormat = .rgba8;
    pub const index_size_bytes: u8 = @sizeOf(u32);
};

/// Primitive output uses straight alpha. Text output is premultiplied alpha.
/// Both blend with `target * (1 - source alpha)` and add.
pub const blending = struct {
    pub const primitives = Blend{
        .color = .{ .source = .source_alpha, .target = .one_minus_source_alpha },
        .alpha = .{ .source = .one, .target = .one_minus_source_alpha },
    };
    pub const text = Blend{
        .color = .{ .source = .one, .target = .one_minus_source_alpha },
        .alpha = .{ .source = .one, .target = .one_minus_source_alpha },
    };
};

/// The blend operation is always addition.
pub const BlendFactor = enum { zero, one, source_alpha, one_minus_source_alpha };

pub const BlendComponent = struct {
    source: BlendFactor,
    target: BlendFactor,
};

pub const Blend = struct {
    color: BlendComponent,
    alpha: BlendComponent,
};

pub const layouts = struct {
    pub const primitive_stride_bytes: u32 = @sizeOf(Vertex);
    pub const instance_stride_bytes: u32 = @sizeOf(Instance);
    pub const text_stride_bytes: u32 = @sizeOf(SlugInstance);
    /// Instance and text buffers advance once per instance. Each attribute is one
    /// field of `Vertex`, `Instance` or `SlugInstance`, in declaration order.
    pub const text_per_instance = true;
};

comptime {
    std.debug.assert(@sizeOf(PrimitiveUniform) == 8);
    std.debug.assert(@sizeOf(TextUniform) == 80);
}
