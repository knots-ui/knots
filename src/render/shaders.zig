//! WGSL and Vulkan Zig shader sources of the bundled renderer. They are plain
//! text, so a renderer for another graphics API can read or translate them.
//! The compiled SPIR-V lives in the `renderer` module, which owns the build step.

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
