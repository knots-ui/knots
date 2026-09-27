//! Mutable tessellation storage. `Packet` is its immutable, ordered projection.

const std = @import("std");
const types = @import("render_types");
const math = @import("math");
const Clip = @import("Clip.zig");
const Packet = @import("Packet.zig");
const GlyphAtlas = @import("GlyphAtlas.zig");

pub const MAX_LAYERS = 256;

pub const Command = @import("Command.zig").Command;
pub const TextureHandle = @import("Command.zig").TextureHandle;
pub const TextureSource = @import("Command.zig").TextureSource;
pub const CustomDrawCallback = @import("Command.zig").CustomDrawCallback;

const LayerRange = struct { start: u32 = 0, len: u32 = 0 };
const BackdropGroup = struct { layer: u8, blur: f32 };

pub const TextBatch = struct {
    clip: Clip.State,
};

allocator: std.mem.Allocator,
vertices: std.ArrayList(types.Vertex),
indices: std.ArrayList(u32),
instances: std.ArrayList(types.Instance),
text_instances: std.ArrayList(types.SlugInstance),
clip_nodes: std.ArrayList(Clip.Node),
layer_cmds: std.ArrayList(Command),
layer_ranges: [MAX_LAYERS]LayerRange,
layers_dirty: std.StaticBitSet(MAX_LAYERS),
current_layer: u8,
/// Indexed by group id: one per layer and blur amount.
backdrop_groups: std.ArrayList(BackdropGroup),

const DrawList = @This();

pub fn init(allocator: std.mem.Allocator) DrawList {
    return .{
        .allocator = allocator,
        .indices = .empty,
        .vertices = .empty,
        .instances = .empty,
        .text_instances = .empty,
        .clip_nodes = .empty,
        .layer_cmds = .empty,
        .layer_ranges = @splat(.{}),
        .layers_dirty = .empty,
        .current_layer = 0,
        .backdrop_groups = .empty,
    };
}

pub fn deinit(self: *DrawList) void {
    self.vertices.deinit(self.allocator);
    self.indices.deinit(self.allocator);
    self.instances.deinit(self.allocator);
    self.text_instances.deinit(self.allocator);
    self.clip_nodes.deinit(self.allocator);
    self.layer_cmds.deinit(self.allocator);
    self.backdrop_groups.deinit(self.allocator);
}

pub fn reset(self: *DrawList) void {
    self.vertices.clearRetainingCapacity();
    self.indices.clearRetainingCapacity();
    self.instances.clearRetainingCapacity();
    self.text_instances.clearRetainingCapacity();
    self.clip_nodes.clearRetainingCapacity();
    self.layer_cmds.clearRetainingCapacity();
    self.layers_dirty = .empty;
    self.current_layer = 0;
    self.backdrop_groups.clearRetainingCapacity();
}

pub fn setLayer(self: *DrawList, layer: u8) void {
    self.current_layer = layer;
}

pub fn isEmpty(self: *const DrawList) bool {
    return self.layer_cmds.items.len == 0;
}

/// Flatten bounded layers into draw order without dropping backend capabilities.
/// The caller retains `portable_commands`; all returned slices are borrowed.
pub fn buildPacket(
    self: *const DrawList,
    portable_commands: *std.ArrayList(Command),
    glyph_atlas: ?GlyphAtlas,
) !Packet {
    return self.buildPacketRange(portable_commands, glyph_atlas, 0, MAX_LAYERS);
}

/// Flatten one bounded half-open layer range into draw order.
pub fn buildPacketRange(
    self: *const DrawList,
    portable_commands: *std.ArrayList(Command),
    glyph_atlas: ?GlyphAtlas,
    layer_min: u32,
    layer_max: u32,
) !Packet {
    if (self.layer_cmds.items.len > Packet.commands_max) return error.TooManyDrawCommands;
    if (layer_min > layer_max) return error.InvalidLayerRange;
    if (layer_max > MAX_LAYERS) return error.InvalidLayerRange;
    portable_commands.clearRetainingCapacity();
    try portable_commands.ensureTotalCapacity(self.allocator, self.layer_cmds.items.len);

    var layer = layer_min;
    while (layer < layer_max) : (layer += 1) {
        if (!self.layers_dirty.isSet(layer)) continue;
        const range = self.layer_ranges[layer];
        const start: usize = range.start;
        const end = start + range.len;
        if (end > self.layer_cmds.items.len) return error.CorruptDrawStream;

        for (self.layer_cmds.items[start..end]) |command| {
            switch (command.payload) {
                .vertex => |draw| try validateRange(draw.offset, draw.count, self.indices.items.len),
                .instance => |draw| try validateRange(draw.offset, draw.count, self.instances.items.len),
                .text => |draw| try validateRange(draw.offset, draw.count, self.text_instances.items.len),
                .custom_draw, .backdrop => {},
            }
            portable_commands.appendAssumeCapacity(command);
        }
    }

    return .init(
        portable_commands.items,
        self.vertices.items,
        self.indices.items,
        self.instances.items,
        self.text_instances.items,
        self.clip_nodes.items,
        glyph_atlas,
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
        .custom_draw, .backdrop => false,
    };
}

fn textureSourceEql(a: TextureSource, b: TextureSource) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .atlas => true,
        .texture => |texture| std.meta.eql(texture, b.texture),
        // Pixel commands stay separate so each command retains its exact update metadata.
        .pixels => false,
    };
}

fn beginCommand(self: *DrawList, payload: Command.Payload, clip: Clip.State) !void {
    if (self.layer_cmds.items.len == Packet.commands_max) return error.TooManyDrawCommands;
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
    vertices: []const types.Vertex,
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
    insts: []const types.Instance,
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
    paint: *const @import("Command.zig").PaintCallback,
    bounds: math.Rect,
    clip: Clip.State,
) !void {
    paint.validate();
    try self.beginCommand(.{ .custom_draw = .{
        .paint = paint.*,
        .bounds = bounds,
    } }, clip);
}

/// Filter what is already painted behind `bounds`. Backdrops in one layer with
/// the same blur share the snapshot taken at the first of them.
pub fn pushBackdrop(
    self: *DrawList,
    bounds: math.Rect,
    corner_radius: [4]f32,
    material: types.Material,
    clip: Clip.State,
) !void {
    std.debug.assert(material.isValid());
    if (bounds.isEmpty()) return;
    const key: BackdropGroup = .{ .layer = self.current_layer, .blur = material.blur };
    const group = for (self.backdrop_groups.items, 0..) |existing, index| {
        if (std.meta.eql(existing, key)) break index;
    } else blk: {
        if (self.backdrop_groups.items.len == Command.Backdrop.groups_max) return error.TooManyBackdropGroups;
        try self.backdrop_groups.append(self.allocator, key);
        break :blk self.backdrop_groups.items.len - 1;
    };
    try self.beginCommand(.{ .backdrop = .{
        .bounds = bounds,
        .corner_radius = corner_radius,
        .material = material,
        .group = @intCast(group),
    } }, clip);
}

pub fn beginTextBatch(self: *DrawList, glyph_count_max: usize, clip: Clip.State) !?TextBatch {
    if (glyph_count_max == 0) return null;
    try self.text_instances.ensureUnusedCapacity(self.allocator, glyph_count_max);
    return .{ .clip = clip };
}

pub fn pushTextInstance(self: *DrawList, batch: TextBatch, instance: types.SlugInstance) !void {
    std.debug.assert(self.text_instances.items.len < self.text_instances.capacity);
    std.debug.assert(instance.origin_size[2] > 0);
    if (!self.lastCmdMatches(.text, .atlas, batch.clip)) {
        try self.beginCommand(.{ .text = .{
            .offset = @intCast(self.text_instances.items.len),
            .count = 0,
        } }, batch.clip);
    }

    var out = instance;
    out.clip_node = @floatFromInt(batch.clip.node);
    self.text_instances.appendAssumeCapacity(out);
    self.lastCommand().payload.text.count += 1;
}

test "packet preserves layer order, images, and custom callbacks" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    var packet_commands: std.ArrayList(Command) = .empty;
    defer packet_commands.deinit(std.testing.allocator);

    const vertex: types.Vertex = std.mem.zeroes(types.Vertex);
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
    const texture: TextureHandle = .{ .extension = .knots, .pointer = @ptrFromInt(0x1000) };
    try draw_list.push(&.{vertex}, &.{0}, .{ .texture = texture }, .{});
    const image_packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expectEqualDeep(draw_list.layer_cmds.items[0], image_packet.commands()[0]);

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
    const pixels_packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expectEqualDeep(draw_list.layer_cmds.items[0], pixels_packet.commands()[0]);

    draw_list.reset();
    try draw_list.pushCustomDraw(&.{ .extension = .knots, .callback = testDrawCallback, .user_data = null }, .zero, .{});
    const custom_packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expectEqual(testDrawCallback, custom_packet.commands()[0].payload.custom_draw.paint.callback);
}

test "backdrops group per layer and blur" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    var packet_commands: std.ArrayList(Command) = .empty;
    defer packet_commands.deinit(std.testing.allocator);
    const rect = math.Rect.init(0, 0, 10, 10);
    const radii: [4]f32 = @splat(2);

    draw_list.setLayer(3);
    try draw_list.pushBackdrop(rect, radii, .{ .blur = 4 }, .{});
    try draw_list.push(&.{std.mem.zeroes(types.Vertex)}, &.{0}, .atlas, .{});
    try draw_list.pushBackdrop(rect, radii, .{ .blur = 4 }, .{});
    try draw_list.pushBackdrop(rect, radii, .{ .blur = 8 }, .{});
    draw_list.setLayer(1);
    try draw_list.pushBackdrop(rect, radii, .{ .blur = 4 }, .{});
    try draw_list.pushBackdrop(.zero, radii, .{ .blur = 4 }, .{});

    const packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expect(packet.hasBackdrop());
    var groups: std.ArrayList(u32) = .empty;
    defer groups.deinit(std.testing.allocator);
    for (packet.commands()) |command| switch (command.payload) {
        .backdrop => |backdrop| try groups.append(std.testing.allocator, backdrop.group),
        else => {},
    };
    // Packet order puts layer 1 first; empty bounds are dropped.
    try std.testing.expectEqualSlices(u32, &.{ 2, 0, 0, 1 }, groups.items);
}

fn testDrawCallback(_: ?*anyopaque, _: *anyopaque) !void {}
