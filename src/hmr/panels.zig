//! Places a module's packet, drawn at the origin, into its region of the host.

const std = @import("std");
const math = @import("math");
const render = @import("render");

/// A packet whose geometry the host owns, so it can be moved in place.
/// The fields match `render.Packet`, so `wire` decodes a packet into it.
pub const Parts = struct {
    commands_value: []render.Command,
    primitive_vertices_value: []render.types.Vertex,
    primitive_indices_value: []const u32,
    instances_value: []render.types.Instance,
    text_instances_value: []render.types.SlugInstance,
    clip_nodes_value: []render.Clip.Node,
    glyph_atlas_value: ?render.GlyphAtlas,
};

pub fn copy(allocator: std.mem.Allocator, packet: *const render.Packet) !Parts {
    return .{
        .commands_value = try allocator.dupe(render.Command, packet.commands()),
        .primitive_vertices_value = try allocator.dupe(render.types.Vertex, packet.primitiveVertices()),
        .primitive_indices_value = packet.primitiveIndices(),
        .instances_value = try allocator.dupe(render.types.Instance, packet.instances()),
        .text_instances_value = try allocator.dupe(render.types.SlugInstance, packet.textInstances()),
        .clip_nodes_value = try allocator.dupe(render.Clip.Node, packet.clipNodes()),
        .glyph_atlas_value = packet.glyphAtlas(),
    };
}

/// Moves the geometry into `rect`. Each module has its own painter, so only
/// the glyph atlas id must change: every guest numbers its atlases from 1.
pub fn place(parts: Parts, atlas_id: u32, rect: math.Rect) !render.Packet {
    for (parts.primitive_vertices_value) |*vertex| {
        vertex.pos[0] += rect.x();
        vertex.pos[1] += rect.y();
    }

    for (parts.instances_value) |*instance| {
        instance.pos[0] += rect.x();
        instance.pos[1] += rect.y();
    }

    for (parts.text_instances_value) |*text| {
        text.origin_size[0] += rect.x();
        text.origin_size[1] += rect.y();
    }

    for (parts.clip_nodes_value) |*clip| {
        clip.rect[0] += rect.x();
        clip.rect[1] += rect.y();
    }

    for (parts.commands_value) |*command| {
        command.clip.scissor = scissor(command.clip.scissor, rect);
        switch (command.payload) {
            .backdrop => |*draw| draw.bounds = .init(draw.bounds.x() + rect.x(), draw.bounds.y() + rect.y(), draw.bounds.w(), draw.bounds.h()),
            .custom_draw => return error.UnsupportedRenderExtension,
            .vertex, .instance, .text => {},
        }
    }

    var atlas = parts.glyph_atlas_value;
    if (atlas) |*value|
        value.id = atlas_id;

    return .init(
        parts.commands_value,
        parts.primitive_vertices_value,
        parts.primitive_indices_value,
        parts.instances_value,
        parts.text_instances_value,
        parts.clip_nodes_value,
        atlas,
    );
}

fn scissor(clip: ?math.Rect, rect: math.Rect) math.Rect {
    const value = clip orelse return rect;
    return rect.intersect(.init(value.x() + rect.x(), value.y() + rect.y(), value.w(), value.h()));
}
