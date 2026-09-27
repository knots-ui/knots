//! Supported WGSL and Vulkan Zig shader sources.

const cfg = @import("shader_config");

pub const primitives_wgsl: []const u8 = @embedFile("primitives_wgsl");
pub const text_wgsl: []const u8 = @embedFile("slug_wgsl");
/// Extends the primitives module, reusing its bindings and SDF helpers.
pub const backdrop_wgsl: []const u8 = primitives_wgsl ++ "\n" ++ @embedFile("backdrop_wgsl");

pub const vulkan_zig = struct {
    pub const primitives_vertex: []const u8 = @embedFile("primitives_vertex_zig");
    pub const primitives_instance_vertex: []const u8 = @embedFile("primitives_instance_vertex_zig");
    pub const primitives_fragment: []const u8 = @embedFile("primitives_fragment_zig");
    pub const text_vertex: []const u8 = @embedFile("text_vertex_zig");
    pub const text_fragment: []const u8 = @embedFile("text_fragment_zig");
};

const primitives_vert_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("primitives_vert_spv").* else [_]u8{};
const primitives_instance_vert_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("primitives_instance_vert_spv").* else [_]u8{};
const primitives_frag_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("primitives_frag_spv").* else [_]u8{};
const slug_vert_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("slug_vert_spv").* else [_]u8{};
const slug_frag_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("slug_frag_spv").* else [_]u8{};
const backdrop_blur_vert_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("backdrop_blur_vert_spv").* else [_]u8{};
const backdrop_blur_frag_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("backdrop_blur_frag_spv").* else [_]u8{};
const backdrop_glass_vert_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("backdrop_glass_vert_spv").* else [_]u8{};
const backdrop_glass_frag_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("backdrop_glass_frag_spv").* else [_]u8{};

pub const primitives_vert_spv: []align(@alignOf(u32)) const u8 = &primitives_vert_bytes;
pub const primitives_instance_vert_spv: []align(@alignOf(u32)) const u8 = &primitives_instance_vert_bytes;
pub const primitives_frag_spv: []align(@alignOf(u32)) const u8 = &primitives_frag_bytes;
pub const slug_vert_spv: []align(@alignOf(u32)) const u8 = &slug_vert_bytes;
pub const slug_frag_spv: []align(@alignOf(u32)) const u8 = &slug_frag_bytes;
pub const backdrop_blur_vert_spv: []align(@alignOf(u32)) const u8 = &backdrop_blur_vert_bytes;
pub const backdrop_blur_frag_spv: []align(@alignOf(u32)) const u8 = &backdrop_blur_frag_bytes;
pub const backdrop_glass_vert_spv: []align(@alignOf(u32)) const u8 = &backdrop_glass_vert_bytes;
pub const backdrop_glass_frag_spv: []align(@alignOf(u32)) const u8 = &backdrop_glass_frag_bytes;
