//! Panel input routing and packet placement, shared by all execution modes.
const std = @import("std");
const math = @import("math");
const render = @import("render");

const Rect = math.Rect;

pub const Resources = struct {
    atlas_id: u32,
    generation: u32 = 1,
    pixels: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    pub fn init() Resources {
        return .{ .atlas_id = render.GlyphAtlas.allocateId() };
    }

    pub fn deinit(self: *Resources, allocator: std.mem.Allocator) void {
        self.pixels.deinit(allocator);
        self.* = undefined;
    }

    pub fn replaced(self: *Resources) !void {
        if (self.generation == std.math.maxInt(u32)) return error.GenerationExhausted;
        self.generation += 1;
        self.atlas_id = render.GlyphAtlas.allocateId();
        self.pixels.clearRetainingCapacity();
    }

    fn texture(self: *Resources, allocator: std.mem.Allocator, source: render.TextureSource) !render.TextureSource {
        switch (source) {
            .atlas => return .atlas,
            .texture => return error.UnsupportedRenderExtension,
            .pixels => |value| {
                if (!self.pixels.contains(value.key)) {
                    if (self.pixels.count() >= 4096) return error.TooManyTextures;
                }
                const entry = try self.pixels.getOrPut(allocator, value.key);
                if (!entry.found_existing) entry.value_ptr.* = self.pixels.count();
                var result = value;
                result.key = (@as(u64, self.generation) << 32) | entry.value_ptr.*;
                return .{ .pixels = result };
            },
        }
    }
};

/// Copy geometry before translating: native module outputs remain borrowed.
/// Every panel uses a distinct Painter, so pixel namespaces are panel-local.
pub fn place(allocator: std.mem.Allocator, resource_allocator: std.mem.Allocator, resources: *Resources, packet: *const render.Packet, rect: Rect) !render.Packet {
    std.debug.assert(rect.w() > 0);
    std.debug.assert(rect.h() > 0);
    const vertices = try allocator.dupe(render.types.Vertex, packet.primitiveVertices());
    for (vertices) |*vertex| {
        vertex.pos[0] += rect.x();
        vertex.pos[1] += rect.y();
    }
    const instances = try allocator.dupe(render.types.Instance, packet.instances());
    for (instances) |*instance| {
        instance.pos[0] += rect.x();
        instance.pos[1] += rect.y();
    }
    const texts = try allocator.dupe(render.types.SlugInstance, packet.textInstances());
    for (texts) |*text| {
        text.origin_size[0] += rect.x();
        text.origin_size[1] += rect.y();
    }
    const clips = try allocator.dupe(render.Clip.Node, packet.clipNodes());
    for (clips) |*clip| {
        clip.rect[0] += rect.x();
        clip.rect[1] += rect.y();
    }
    const commands = try allocator.dupe(render.Command, packet.commands());
    for (commands) |*command| {
        command.clip.scissor = if (command.clip.scissor) |clip| rect.intersect(.init(clip.x() + rect.x(), clip.y() + rect.y(), clip.w(), clip.h())) else rect;
        switch (command.payload) {
            .vertex => |*draw| draw.texture = try resources.texture(resource_allocator, draw.texture),
            .instance => |*draw| draw.texture = try resources.texture(resource_allocator, draw.texture),
            .text => {},
            .backdrop => |*draw| draw.bounds = .init(draw.bounds.x() + rect.x(), draw.bounds.y() + rect.y(), draw.bounds.w(), draw.bounds.h()),
            .custom_draw => return error.UnsupportedRenderExtension,
        }
    }
    var atlas = packet.glyphAtlas();
    if (atlas) |*value| value.id = resources.atlas_id;
    return .init(commands, vertices, packet.primitiveIndices(), instances, texts, clips, atlas);
}
