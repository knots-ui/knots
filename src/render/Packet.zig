//! Immutable render data produced by an embedded `Context`.
//!
//! The packet is independent of a graphics API, but its geometry, glyph atlas,
//! clipping, and shader conventions are Knots' rendering protocol. A renderer
//! using another graphics API must implement those conventions and reject any
//! texture or callback extension it does not support.

const types = @import("render_types");
const Clip = @import("Clip.zig");
const GlyphAtlas = @import("GlyphAtlas.zig");
const Command = @import("Command.zig").Command;

pub const commands_max: u32 = 1 << 20;

/// A contiguous range in the corresponding packet index or instance stream.
pub const Range = struct {
    offset: u32,
    count: u32,
};

/// Every slice is borrowed from its producing `Context` and remains valid until
/// that view begins its next frame or is deinitialized.
commands_value: []const Command,
primitive_vertices_value: []const types.Vertex,
primitive_indices_value: []const u32,
instances_value: []const types.Instance,
text_instances_value: []const types.SlugInstance,
clip_nodes_value: []const Clip.Node,
glyph_atlas_value: ?GlyphAtlas,

const Packet = @This();

pub fn init(
    commands_value: []const Command,
    primitive_vertices_value: []const types.Vertex,
    primitive_indices_value: []const u32,
    instances_value: []const types.Instance,
    text_instances_value: []const types.SlugInstance,
    clip_nodes_value: []const Clip.Node,
    glyph_atlas_value: ?GlyphAtlas,
) Packet {
    return .{
        .commands_value = commands_value,
        .primitive_vertices_value = primitive_vertices_value,
        .primitive_indices_value = primitive_indices_value,
        .instances_value = instances_value,
        .text_instances_value = text_instances_value,
        .clip_nodes_value = clip_nodes_value,
        .glyph_atlas_value = glyph_atlas_value,
    };
}

pub fn commands(self: *const Packet) []const Command {
    return self.commands_value;
}

pub fn primitiveVertices(self: *const Packet) []const types.Vertex {
    return self.primitive_vertices_value;
}

pub fn primitiveIndices(self: *const Packet) []const u32 {
    return self.primitive_indices_value;
}

pub fn instances(self: *const Packet) []const types.Instance {
    return self.instances_value;
}

pub fn textInstances(self: *const Packet) []const types.SlugInstance {
    return self.text_instances_value;
}

pub fn clipNodes(self: *const Packet) []const Clip.Node {
    return self.clip_nodes_value;
}

pub fn glyphAtlas(self: *const Packet) ?GlyphAtlas {
    return self.glyph_atlas_value;
}

/// Whether any command filters its backdrop, which needs a sampleable scene target.
pub fn hasBackdrop(self: *const Packet) bool {
    for (self.commands_value) |command| {
        if (command.payload == .backdrop) return true;
    }
    return false;
}

/// Reject incompatible renderer extensions before interpreting erased data.
pub fn validateExtensions(self: *const Packet, supported: ?@import("Command.zig").Extension) !void {
    if (self.commands_value.len > commands_max) return error.TooManyDrawCommands;
    for (self.commands_value) |command| {
        switch (command.payload) {
            .vertex => |draw| try validateTexture(draw.texture, supported),
            .instance => |draw| try validateTexture(draw.texture, supported),
            .text => {},
            .backdrop => |draw| {
                if (draw.group >= Command.Backdrop.groups_max) return error.InvalidBackdrop;
                if (!draw.material.isValid()) return error.InvalidBackdrop;
            },
            .custom_draw => |draw| {
                const extension = supported orelse return error.UnsupportedRenderExtension;
                if (draw.paint.extension != extension) return error.UnsupportedRenderExtension;
            },
        }
    }
}
fn validateTexture(source: @import("Command.zig").TextureSource, supported: ?@import("Command.zig").Extension) !void {
    switch (source) {
        .atlas, .pixels => {},
        .texture => |handle| {
            const extension = supported orelse return error.UnsupportedRenderExtension;
            if (handle.extension != extension) return error.UnsupportedRenderExtension;
        },
    }
}
