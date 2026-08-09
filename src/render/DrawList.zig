//! Draw stream UI tessellation writes into. `Packet` is its portable projection.

const std = @import("std");
const gpu = @import("gpu");
const math = @import("math");
const Clip = @import("Clip.zig");
const Packet = @import("Packet.zig");

pub const MAX_LAYERS = 256;

/// Erased so `ui` builds draw lists without a GPU backend; the renderer casts back.
pub const TextureHandle = opaque {};

/// `draw_context` is the renderer's own context (`renderer.gpu.DrawContext` for
/// Knots'), erased like `TextureHandle` and restored before the call.
pub const CustomDrawCallback = *const fn (
    user_data: ?*anyopaque,
    draw_context: *anyopaque,
) anyerror!void;

pub const TextureSource = union(enum) {
    atlas,
    texture: *const TextureHandle,
    pixels: Pixels,

    pub const Pixels = struct {
        key: u64,
        data: []const u8,
        width: u32,
        height: u32,
        format: gpu.Texture.Format,
        bytes_per_row: ?u32,
        version: u64,
        force_upload: bool,
    };
};

pub const Command = struct {
    clip: Clip.State,
    payload: Payload,

    pub const Kind = enum {
        vertex,
        instance,
        text,
        custom_draw,
    };

    pub const Payload = union(Kind) {
        vertex: Indexed,
        instance: Instanced,
        text: Text,
        custom_draw: CustomDraw,
    };

    pub const Indexed = struct {
        texture: TextureSource,
        offset: u32,
        count: u32,
    };

    pub const Instanced = struct {
        texture: TextureSource,
        offset: u32,
        count: u32,
    };

    pub const Text = struct {
        offset: u32,
        count: u32,
    };

    pub const CustomDraw = struct {
        callback: CustomDrawCallback,
        user_data: ?*anyopaque,
        bounds: math.Rect,
    };
};

const LayerRange = struct { start: u32 = 0, len: u32 = 0 };

pub const TextBatch = struct {
    clip: Clip.State,
};

allocator: std.mem.Allocator,
vertices: std.ArrayList(gpu.Vertex),
indices: std.ArrayList(u32),
instances: std.ArrayList(gpu.Instance),
text_vertices: std.ArrayList(gpu.SlugVertex),
text_indices: std.ArrayList(u32),
clip_nodes: std.ArrayList(Clip.Node),
layer_cmds: std.ArrayList(Command),
layer_ranges: [MAX_LAYERS]LayerRange,
layers_dirty: std.StaticBitSet(MAX_LAYERS),
current_layer: u8,

const DrawList = @This();

pub fn init(allocator: std.mem.Allocator) DrawList {
    return .{
        .allocator = allocator,
        .indices = .empty,
        .vertices = .empty,
        .instances = .empty,
        .text_vertices = .empty,
        .text_indices = .empty,
        .clip_nodes = .empty,
        .layer_cmds = .empty,
        .layer_ranges = @splat(.{}),
        .layers_dirty = .empty,
        .current_layer = 0,
    };
}

pub fn deinit(self: *DrawList) void {
    self.vertices.deinit(self.allocator);
    self.indices.deinit(self.allocator);
    self.instances.deinit(self.allocator);
    self.text_vertices.deinit(self.allocator);
    self.text_indices.deinit(self.allocator);
    self.clip_nodes.deinit(self.allocator);
    self.layer_cmds.deinit(self.allocator);
}

pub fn reset(self: *DrawList) void {
    self.vertices.clearRetainingCapacity();
    self.indices.clearRetainingCapacity();
    self.instances.clearRetainingCapacity();
    self.text_vertices.clearRetainingCapacity();
    self.text_indices.clearRetainingCapacity();
    self.clip_nodes.clearRetainingCapacity();
    self.layer_cmds.clearRetainingCapacity();
    self.layers_dirty = .empty;
    self.current_layer = 0;
}

pub fn setLayer(self: *DrawList, layer: u8) void {
    self.current_layer = layer;
}

pub fn isEmpty(self: *const DrawList) bool {
    return self.layer_cmds.items.len == 0;
}

/// Project the finalized desktop draw stream into the portable packet subset.
///
/// Pixel images and custom GPU draws intentionally remain desktop-only. The
/// caller retains `portable_commands` so every returned slice is borrowed.
pub fn buildPacket(
    self: *const DrawList,
    portable_commands: *std.ArrayList(Packet.Command),
    glyph_update: ?Packet.GlyphUpdate,
) !Packet {
    portable_commands.clearRetainingCapacity();
    try portable_commands.ensureTotalCapacity(self.allocator, self.layer_cmds.items.len);

    var layer: usize = 0;
    while (layer < MAX_LAYERS) : (layer += 1) {
        if (!self.layers_dirty.isSet(layer)) continue;
        const range = self.layer_ranges[layer];
        const start: usize = range.start;
        const end = start + range.len;
        if (end > self.layer_cmds.items.len) return error.CorruptDrawStream;

        for (self.layer_cmds.items[start..end]) |command| {
            const payload: Packet.Command.Payload = switch (command.payload) {
                .vertex => |draw| blk: {
                    if (draw.texture != .atlas) return error.ImageUnsupported;
                    try validateRange(draw.offset, draw.count, self.indices.items.len);
                    break :blk .{ .primitive = .{
                        .offset = draw.offset,
                        .count = draw.count,
                    } };
                },
                .instance => |draw| blk: {
                    if (draw.texture != .atlas) return error.ImageUnsupported;
                    try validateRange(draw.offset, draw.count, self.instances.items.len);
                    break :blk .{ .instances = .{
                        .offset = draw.offset,
                        .count = draw.count,
                    } };
                },
                .text => |draw| blk: {
                    try validateRange(draw.offset, draw.count, self.text_indices.items.len);
                    break :blk .{ .text = .{
                        .offset = draw.offset,
                        .count = draw.count,
                    } };
                },
                .custom_draw => return error.GPUCanvasUnsupported,
            };
            portable_commands.appendAssumeCapacity(.{
                .clip = command.clip,
                .payload = payload,
            });
        }
    }

    return .init(
        portable_commands.items,
        self.vertices.items,
        self.indices.items,
        self.instances.items,
        self.text_vertices.items,
        self.text_indices.items,
        self.clip_nodes.items,
        glyph_update,
    );
}

fn validateRange(offset: u32, count: u32, length: usize) !void {
    const end = @as(u64, offset) + count;
    if (end > @as(u64, @intCast(length))) return error.CorruptDrawStream;
}

fn lastCmdMatches(
    self: *const DrawList,
    kind: Command.Kind,
    texture: TextureSource,
    clip: Clip.State,
) bool {
    if (!self.layers_dirty.isSet(self.current_layer)) return false;
    const range = self.layer_ranges[self.current_layer];
    if (range.len == 0) return false;
    const last = self.layer_cmds.items[range.start + range.len - 1];
    if (std.meta.activeTag(last.payload) != kind or !last.clip.scissorEql(clip)) return false;
    return switch (last.payload) {
        .vertex => |cmd| textureSourceEql(cmd.texture, texture),
        .instance => |cmd| textureSourceEql(cmd.texture, texture),
        .text => texture == .atlas,
        .custom_draw => false,
    };
}

fn textureSourceEql(a: TextureSource, b: TextureSource) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .atlas => true,
        .texture => |texture| texture == b.texture,
        // Pixel commands stay separate so each command retains its exact update metadata.
        .pixels => false,
    };
}

fn beginCommand(self: *DrawList, payload: Command.Payload, clip: Clip.State) !void {
    const range = &self.layer_ranges[self.current_layer];
    if (!self.layers_dirty.isSet(self.current_layer)) {
        range.start = @intCast(self.layer_cmds.items.len);
        range.len = 0;
        self.layers_dirty.set(self.current_layer);
    }
    try self.layer_cmds.append(self.allocator, .{ .clip = clip, .payload = payload });
    range.len += 1;
}

fn lastCommand(self: *DrawList) *Command {
    const range = self.layer_ranges[self.current_layer];
    return &self.layer_cmds.items[range.start + range.len - 1];
}

pub fn push(
    self: *DrawList,
    vertices: []const gpu.Vertex,
    indices: []const u32,
    texture: TextureSource,
    clip: Clip.State,
) !void {
    if (!self.lastCmdMatches(.vertex, texture, clip)) {
        try self.beginCommand(.{ .vertex = .{
            .texture = texture,
            .offset = @intCast(self.indices.items.len),
            .count = 0,
        } }, clip);
    }

    const vertex_base: u32 = @intCast(self.vertices.items.len);
    try self.indices.ensureUnusedCapacity(self.allocator, indices.len);
    for (indices) |idx| self.indices.appendAssumeCapacity(idx + vertex_base);

    try self.vertices.ensureUnusedCapacity(self.allocator, vertices.len);
    const clip_node: f32 = @floatFromInt(clip.node);
    for (vertices) |v| {
        var out = v;
        out.clip_node = clip_node;
        self.vertices.appendAssumeCapacity(out);
    }
    self.lastCommand().payload.vertex.count += @intCast(indices.len);
}

pub fn pushInstances(
    self: *DrawList,
    insts: []const gpu.Instance,
    texture: TextureSource,
    clip: Clip.State,
) !void {
    if (insts.len == 0) return;
    if (!self.lastCmdMatches(.instance, texture, clip)) {
        try self.beginCommand(.{ .instance = .{
            .texture = texture,
            .offset = @intCast(self.instances.items.len),
            .count = 0,
        } }, clip);
    }

    try self.instances.ensureUnusedCapacity(self.allocator, insts.len);
    const clip_node: f32 = @floatFromInt(clip.node);
    for (insts) |inst| {
        var out = inst;
        out.clip_node = clip_node;
        self.instances.appendAssumeCapacity(out);
    }
    self.lastCommand().payload.instance.count += @intCast(insts.len);
}

pub fn pushCustomDraw(
    self: *DrawList,
    callback: CustomDrawCallback,
    user_data: ?*anyopaque,
    bounds: math.Rect,
    clip: Clip.State,
) !void {
    try self.beginCommand(.{ .custom_draw = .{
        .callback = callback,
        .user_data = user_data,
        .bounds = bounds,
    } }, clip);
}

pub fn pushText(
    self: *DrawList,
    verts: []const gpu.SlugVertex,
    indices: []const u32,
    clip: Clip.State,
) !void {
    if (verts.len == 0 or indices.len == 0) return;
    if (!self.lastCmdMatches(.text, .atlas, clip)) {
        try self.beginCommand(.{ .text = .{
            .offset = @intCast(self.text_indices.items.len),
            .count = 0,
        } }, clip);
    }

    const vertex_base: u32 = @intCast(self.text_vertices.items.len);
    try self.text_indices.ensureUnusedCapacity(self.allocator, indices.len);
    for (indices) |idx| self.text_indices.appendAssumeCapacity(idx + vertex_base);
    try self.text_vertices.ensureUnusedCapacity(self.allocator, verts.len);
    const clip_node: f32 = @floatFromInt(clip.node);
    for (verts) |v| {
        var out = v;
        out.clip_node = clip_node;
        self.text_vertices.appendAssumeCapacity(out);
    }
    self.lastCommand().payload.text.count += @intCast(indices.len);
}

pub fn beginTextBatch(self: *DrawList, max_quads: usize, clip: Clip.State) !?TextBatch {
    if (max_quads == 0) return null;
    try self.text_vertices.ensureUnusedCapacity(self.allocator, max_quads * 4);
    try self.text_indices.ensureUnusedCapacity(self.allocator, max_quads * 6);
    return .{ .clip = clip };
}

pub fn pushTextQuad(self: *DrawList, batch: TextBatch, verts: [4]gpu.SlugVertex) !void {
    if (!self.lastCmdMatches(.text, .atlas, batch.clip)) {
        try self.beginCommand(.{ .text = .{
            .offset = @intCast(self.text_indices.items.len),
            .count = 0,
        } }, batch.clip);
    }

    const vertex_base: u32 = @intCast(self.text_vertices.items.len);
    const clip_node: f32 = @floatFromInt(batch.clip.node);
    inline for (0..4) |i| {
        var out = verts[i];
        out.clip_node = clip_node;
        self.text_vertices.appendAssumeCapacity(out);
    }
    self.text_indices.appendAssumeCapacity(vertex_base + 0);
    self.text_indices.appendAssumeCapacity(vertex_base + 1);
    self.text_indices.appendAssumeCapacity(vertex_base + 2);
    self.text_indices.appendAssumeCapacity(vertex_base + 0);
    self.text_indices.appendAssumeCapacity(vertex_base + 2);
    self.text_indices.appendAssumeCapacity(vertex_base + 3);
    self.lastCommand().payload.text.count += 6;
}

test "packet preserves layer order and rejects desktop-only commands" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    var packet_commands: std.ArrayList(Packet.Command) = .empty;
    defer packet_commands.deinit(std.testing.allocator);

    const vertex: gpu.Vertex = std.mem.zeroes(gpu.Vertex);
    draw_list.setLayer(2);
    try draw_list.push(&.{vertex}, &.{0}, .atlas, .{ .node = 2 });
    draw_list.setLayer(0);
    try draw_list.push(&.{vertex}, &.{0}, .atlas, .{ .node = 0 });

    const packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expectEqual(@as(usize, 2), packet.commands().len);
    try std.testing.expectEqual(@as(u32, 0), packet.commands()[0].clip.node);
    try std.testing.expectEqual(@as(u32, 2), packet.commands()[1].clip.node);
    try std.testing.expectEqual(@as(usize, 2), packet.primitiveVertices().len);
    try std.testing.expectEqual(@as(usize, 2), packet.primitiveIndices().len);

    draw_list.layer_cmds.items[0].payload.vertex.count = 3;
    try std.testing.expectError(
        error.CorruptDrawStream,
        draw_list.buildPacket(&packet_commands, null),
    );

    draw_list.reset();
    const texture: *const TextureHandle = @ptrFromInt(0x1000);
    try draw_list.push(&.{vertex}, &.{0}, .{ .texture = texture }, .{});
    try std.testing.expectError(
        error.ImageUnsupported,
        draw_list.buildPacket(&packet_commands, null),
    );

    draw_list.reset();
    try draw_list.push(&.{vertex}, &.{0}, .{ .pixels = .{
        .key = 1,
        .data = &.{},
        .width = 1,
        .height = 1,
        .format = .rgba8,
        .bytes_per_row = null,
        .version = 0,
        .force_upload = true,
    } }, .{});
    try std.testing.expectError(
        error.ImageUnsupported,
        draw_list.buildPacket(&packet_commands, null),
    );

    draw_list.reset();
    try draw_list.pushCustomDraw(testDrawCallback, null, .zero, .{});
    try std.testing.expectError(
        error.GPUCanvasUnsupported,
        draw_list.buildPacket(&packet_commands, null),
    );
}

fn testDrawCallback(_: ?*anyopaque, _: *anyopaque) !void {}
