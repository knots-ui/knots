const std = @import("std");
const gpu = render.types;
const render = @import("render");

const PortableEncoder = struct {
    primitive_indices: u32 = 0,
    instances: u32 = 0,
    text_instances: u32 = 0,

    fn encode(self: *PortableEncoder, packet: *const render.Packet) !void {
        try packet.validateExtensions(null);
        for (packet.commands()) |command| {
            try validateClip(command.clip, packet.clipNodes());
            switch (command.payload) {
                .vertex => |range| {
                    try validateRange(.{ .offset = range.offset, .count = range.count }, packet.primitiveIndices().len);
                    self.primitive_indices += range.count;
                },
                .instance => |range| {
                    try validateRange(.{ .offset = range.offset, .count = range.count }, packet.instances().len);
                    self.instances += range.count;
                },
                .text => |range| {
                    try validateRange(.{ .offset = range.offset, .count = range.count }, packet.textInstances().len);
                    self.text_instances += range.count;
                },
                .custom_draw => return error.UnsupportedCallback,
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
            .vertex => |range| range.count,
            .instance => |range| range.count,
            .text => |range| range.count,
            .custom_draw => 0,
        };
    }
    total += packet.primitiveVertices().len;
    total += packet.primitiveIndices().len;
    total += packet.instances().len;
    total += packet.textInstances().len;
    total += packet.clipNodes().len;
    return total;
}

test "consumer needs only the public render module" {
    const primitive_vertices = [_]gpu.Vertex{std.mem.zeroes(gpu.Vertex)};
    const primitive_indices = [_]u32{0};
    const clip_nodes = [_]render.Clip.Node{render.Clip.Node.empty};
    const commands = [_]render.DrawList.Command{.{
        .clip = .{},
        .payload = .{ .vertex = .{ .texture = .atlas, .offset = 0, .count = 1 } },
    }};
    const packet = render.Packet.init(
        &commands,
        &primitive_vertices,
        &primitive_indices,
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

test "foreign textures and callbacks are rejected before pointer interpretation" {
    const commands = [_]render.Command{
        .{ .clip = .{}, .payload = .{ .vertex = .{
            .texture = .{ .texture = .{ .extension = @fromBackingInt(@intCast(123)), .pointer = @ptrFromInt(0x1000) } },
            .offset = 0,
            .count = 0,
        } } },
        .{ .clip = .{}, .payload = .{ .custom_draw = .{
            .paint = .{
                .extension = @fromBackingInt(@intCast(123)),
                .callback = struct {
                    fn draw(_: ?*anyopaque, _: *anyopaque) !void {
                        return error.MustNotExecute;
                    }
                }.draw,
                .user_data = null,
            },
            .bounds = .zero,
        } } },
    };
    for (0..2) |index| {
        const packet = render.Packet.init(commands[index .. index + 1], &.{}, &.{}, &.{}, &.{}, &.{}, null);
        try std.testing.expectError(error.UnsupportedRenderExtension, packet.validateExtensions(.knots));
        try std.testing.expectError(error.UnsupportedRenderExtension, packet.validateExtensions(null));
        try packet.validateExtensions(@fromBackingInt(@intCast(123)));
    }
}
