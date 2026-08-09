//! Immutable, backend-neutral render data produced by an embedded `View`.

const gpu = @import("gpu");
const Clip = @import("Clip.zig");

/// A contiguous range in the corresponding packet index or instance stream.
pub const Range = struct {
    offset: u32,
    count: u32,
};

/// A portable draw command. Commands are already ordered by layer and must be
/// encoded without reordering.
pub const Command = struct {
    clip: Clip.State,
    payload: Payload,

    pub const Payload = union(enum) {
        primitive: Range,
        instances: Range,
        text: Range,
    };
};

/// A dirty rectangular run from one glyph-atlas plane.
///
/// `bytes` contains tightly packed texels. The final row can be partial; hosts
/// zero-pad it to `row_bytes` before a rectangular texture upload.
pub const GlyphPlaneUpdate = struct {
    bytes: []const u8,
    row_start: u32,
    row_end: u32,
    row_texels: u32,
    row_bytes: u32,
    texel_size_bytes: u8,
};

/// Glyph data remains pending until the host acknowledges this generation.
pub const GlyphUpdate = struct {
    generation: u64,
    curve: ?GlyphPlaneUpdate,
    band: ?GlyphPlaneUpdate,
};

/// Every slice is borrowed from its producing `View` and remains valid until
/// that view begins its next frame or is deinitialized.
commands_value: []const Command,
primitive_vertices_value: []const gpu.Vertex,
primitive_indices_value: []const u32,
instances_value: []const gpu.Instance,
text_vertices_value: []const gpu.SlugVertex,
text_indices_value: []const u32,
clip_nodes_value: []const Clip.Node,
glyph_update_value: ?GlyphUpdate,

const Packet = @This();

pub fn init(
    commands_value: []const Command,
    primitive_vertices_value: []const gpu.Vertex,
    primitive_indices_value: []const u32,
    instances_value: []const gpu.Instance,
    text_vertices_value: []const gpu.SlugVertex,
    text_indices_value: []const u32,
    clip_nodes_value: []const Clip.Node,
    glyph_update_value: ?GlyphUpdate,
) Packet {
    return .{
        .commands_value = commands_value,
        .primitive_vertices_value = primitive_vertices_value,
        .primitive_indices_value = primitive_indices_value,
        .instances_value = instances_value,
        .text_vertices_value = text_vertices_value,
        .text_indices_value = text_indices_value,
        .clip_nodes_value = clip_nodes_value,
        .glyph_update_value = glyph_update_value,
    };
}

pub fn commands(self: *const Packet) []const Command {
    return self.commands_value;
}

pub fn primitiveVertices(self: *const Packet) []const gpu.Vertex {
    return self.primitive_vertices_value;
}

pub fn primitiveIndices(self: *const Packet) []const u32 {
    return self.primitive_indices_value;
}

pub fn instances(self: *const Packet) []const gpu.Instance {
    return self.instances_value;
}

pub fn textVertices(self: *const Packet) []const gpu.SlugVertex {
    return self.text_vertices_value;
}

pub fn textIndices(self: *const Packet) []const u32 {
    return self.text_indices_value;
}

pub fn clipNodes(self: *const Packet) []const Clip.Node {
    return self.clip_nodes_value;
}

pub fn glyphUpdate(self: *const Packet) ?GlyphUpdate {
    return self.glyph_update_value;
}
