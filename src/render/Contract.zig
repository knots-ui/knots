//! Vertex layouts, resource bindings, texture formats, and uniform contracts.

const std = @import("std");
const types = @import("render_types");

/// All packet geometry uses logical pixels with the origin at the top-left.
/// Commands are triangle lists, use `u32` indices, disable culling, and must be
/// encoded in packet order. A command's scissor is also expressed in logical
/// pixels and must be intersected with the render target after content scaling.
pub const geometry = struct {
    pub const text_quad_indices = [6]u32{ 0, 1, 2, 0, 2, 3 };
    pub const front_face: types.Pipeline.FrontFace = .ccw;
    pub const cull_mode: types.Pipeline.CullMode = .none;
};

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
    pub const glyph_atlas_group: u32 = 1;
    pub const glyph_curve_atlas: u32 = 0;
    pub const glyph_band_atlas: u32 = 1;
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
    pub const glyph_curve: types.Texture.Format = .rgba32f;
    pub const glyph_band: types.Texture.Format = .rgba32u;
    pub const offscreen_color: types.Texture.Format = .rgba8;
    pub const index_size_bytes: u8 = @sizeOf(u32);
};

/// Primitive output uses straight alpha. Text output is premultiplied alpha.
pub const blending = struct {
    pub const primitives = types.Pipeline.BlendState{
        .color = .{
            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
            .op = .add,
        },
        .alpha = .{
            .src_factor = .one,
            .dst_factor = .one_minus_src_alpha,
            .op = .add,
        },
    };
    pub const text = types.Pipeline.BlendState{
        .color = .{
            .src_factor = .one,
            .dst_factor = .one_minus_src_alpha,
            .op = .add,
        },
        .alpha = .{
            .src_factor = .one,
            .dst_factor = .one_minus_src_alpha,
            .op = .add,
        },
    };
};

pub const layouts = struct {
    pub const primitive_stride_bytes: u32 = @sizeOf(types.Vertex);
    pub const instance_stride_bytes: u32 = @sizeOf(types.Instance);
    pub const text_stride_bytes: u32 = @sizeOf(types.SlugInstance);
    pub const text_step_mode: types.Pipeline.VertexStepMode = .instance;

    pub const primitive_attributes = types.Pipeline.attrsFromStruct(types.Vertex);
    pub const instance_attributes = types.Pipeline.attrsFromStruct(types.Instance);
    pub const text_attributes = types.Pipeline.attrsFromStruct(types.SlugInstance);
};

comptime {
    std.debug.assert(@sizeOf(PrimitiveUniform) == 8);
    std.debug.assert(@sizeOf(TextUniform) == 80);
}
