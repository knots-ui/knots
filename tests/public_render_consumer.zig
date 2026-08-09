const std = @import("std");
const gpu = @import("gpu");
const render = @import("render");

const PortableEncoder = struct {
    primitive_indices: u32 = 0,
    instances: u32 = 0,
    text_indices: u32 = 0,

    fn encode(self: *PortableEncoder, packet: *const render.Packet) !void {
        for (packet.commands()) |command| {
            try validateClip(command.clip, packet.clipNodes());
            switch (command.payload) {
                .primitive => |range| {
                    try validateRange(range, packet.primitiveIndices().len);
                    self.primitive_indices += range.count;
                },
                .instances => |range| {
                    try validateRange(range, packet.instances().len);
                    self.instances += range.count;
                },
                .text => |range| {
                    try validateRange(range, packet.textIndices().len);
                    self.text_indices += range.count;
                },
            }
        }
    }
};

fn validateRange(range: render.Packet.Range, length: usize) !void {
    const end = @as(u64, range.offset) + range.count;
    if (end > @as(u64, @intCast(length))) return error.InvalidPacketRange;
}

fn validateClip(clip: render.Clip.State, nodes: []const render.Clip.Node) !void {
    if (clip.node >= nodes.len) return error.InvalidClipNode;
}

fn packetElementCount(packet: *const render.Packet) u64 {
    var total: u64 = 0;
    for (packet.commands()) |command| {
        total += switch (command.payload) {
            .primitive => |range| range.count,
            .instances => |range| range.count,
            .text => |range| range.count,
        };
    }
    total += packet.primitiveVertices().len;
    total += packet.primitiveIndices().len;
    total += packet.instances().len;
    total += packet.textVertices().len;
    total += packet.textIndices().len;
    total += packet.clipNodes().len;
    return total;
}

test "consumer needs only public render and gpu modules" {
    const primitive_vertices = [_]gpu.Vertex{std.mem.zeroes(gpu.Vertex)};
    const primitive_indices = [_]u32{0};
    const clip_nodes = [_]render.Clip.Node{render.Clip.Node.empty};
    const commands = [_]render.Packet.Command{.{
        .clip = .{},
        .payload = .{ .primitive = .{ .offset = 0, .count = 1 } },
    }};
    const packet = render.Packet.init(
        &commands,
        &primitive_vertices,
        &primitive_indices,
        &.{},
        &.{},
        &.{},
        &clip_nodes,
        null,
    );
    var encoder: PortableEncoder = .{};
    try encoder.encode(&packet);
    try std.testing.expectEqual(@as(u32, 1), encoder.primitive_indices);
    try std.testing.expectEqual(@as(u64, 4), packetElementCount(&packet));
    try std.testing.expectEqual(
        @as(u32, @sizeOf(gpu.Vertex)),
        render.contract.layouts.primitive_stride_bytes,
    );
    try std.testing.expect(render.shaders.primitives_wgsl.len > 0);
    try std.testing.expect(render.shaders.vulkan_zig.primitives_vertex.len > 0);
}
