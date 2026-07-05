const cfg = @import("shader_config");

pub const primitives_wgsl: []const u8 = if (cfg.has_wgsl_shaders) @embedFile("primitives_wgsl") else "";
pub const slug_wgsl: []const u8 = if (cfg.has_wgsl_shaders) @embedFile("slug_wgsl") else "";

const primitives_vert_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("primitives_vert_spv").* else [_]u8{};
const primitives_instance_vert_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("primitives_instance_vert_spv").* else [_]u8{};
const primitives_frag_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("primitives_frag_spv").* else [_]u8{};
const slug_vert_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("slug_vert_spv").* else [_]u8{};
const slug_frag_bytes align(@alignOf(u32)) = if (cfg.has_spirv_shaders) @embedFile("slug_frag_spv").* else [_]u8{};

pub const primitives_vert_spv: []align(@alignOf(u32)) const u8 = &primitives_vert_bytes;
pub const primitives_instance_vert_spv: []align(@alignOf(u32)) const u8 = &primitives_instance_vert_bytes;
pub const primitives_frag_spv: []align(@alignOf(u32)) const u8 = &primitives_frag_bytes;
pub const slug_vert_spv: []align(@alignOf(u32)) const u8 = &slug_vert_bytes;
pub const slug_frag_spv: []align(@alignOf(u32)) const u8 = &slug_frag_bytes;
