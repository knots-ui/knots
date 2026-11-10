//! Shaders of the bundled renderer: the sources from `render.shaders` and the
//! SPIR-V that the build compiles from the Vulkan Zig sources.

const cfg = @import("shader_config");
const sources = @import("render").shaders;

pub const primitives_wgsl = sources.primitives_wgsl;
pub const text_wgsl = sources.text_wgsl;
pub const backdrop_wgsl = sources.backdrop_wgsl;
pub const vulkan_zig = sources.vulkan_zig;

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
