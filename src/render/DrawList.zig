const std = @import("std");
const gpu = @import("gpu");
const Clip = @import("Clip.zig");

pub const MAX_LAYERS = 256;

pub const CommandKind = enum { vertex, instance, text };

pub const Command = struct {
    // .vertex   -> offset/count are index_offset/index_count into `indices`
    // .instance -> offset/count are first_instance/instance_count into `instances`
    // .text     -> offset/count are index_offset/index_count into `text_indices`
    kind: CommandKind,
    texture: ?u32,
    offset: u32,
    count: u32,
    clip: Clip.State,
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
    return DrawList{
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

fn lastCmdMatches(self: *const DrawList, kind: CommandKind, texture: ?u32, clip: Clip.State) bool {
    if (!self.layers_dirty.isSet(self.current_layer)) return false;
    const range = self.layer_ranges[self.current_layer];
    if (range.len == 0) return false;
    const last = &self.layer_cmds.items[range.start + range.len - 1];
    if (last.kind != kind) return false;
    if (last.texture != texture) return false;
    return last.clip.scissorEql(clip);
}

fn beginCommand(self: *DrawList, kind: CommandKind, texture: ?u32, clip: Clip.State, offset: u32) !void {
    const range = &self.layer_ranges[self.current_layer];
    if (!self.layers_dirty.isSet(self.current_layer)) {
        range.start = @intCast(self.layer_cmds.items.len);
        range.len = 0;
        self.layers_dirty.set(self.current_layer);
    }
    try self.layer_cmds.append(self.allocator, .{
        .kind = kind,
        .texture = texture,
        .offset = offset,
        .count = 0,
        .clip = clip,
    });
    range.len += 1;
}

pub fn push(self: *DrawList, vertices: []const gpu.Vertex, indices: []const u32, texture: ?u32, clip: Clip.State) !void {
    if (!self.lastCmdMatches(.vertex, texture, clip)) {
        try self.beginCommand(.vertex, texture, clip, @intCast(self.indices.items.len));
    }

    const range = self.layer_ranges[self.current_layer];
    const vertex_base: u32 = @intCast(self.vertices.items.len);
    try self.indices.ensureUnusedCapacity(self.allocator, indices.len);
    for (indices) |idx| {
        self.indices.appendAssumeCapacity(idx + vertex_base);
    }

    try self.vertices.ensureUnusedCapacity(self.allocator, vertices.len);
    const clip_node: f32 = @floatFromInt(clip.node);
    for (vertices) |v| {
        var out = v;
        out.clip_node = clip_node;
        self.vertices.appendAssumeCapacity(out);
    }
    self.layer_cmds.items[range.start + range.len - 1].count += @intCast(indices.len);
}

pub fn pushInstances(self: *DrawList, insts: []const gpu.Instance, texture: ?u32, clip: Clip.State) !void {
    if (insts.len == 0) return;
    if (!self.lastCmdMatches(.instance, texture, clip)) {
        const first_instance: u32 = @intCast(self.instances.items.len);
        try self.beginCommand(.instance, texture, clip, first_instance);
    }

    const range = self.layer_ranges[self.current_layer];
    try self.instances.ensureUnusedCapacity(self.allocator, insts.len);
    const clip_node: f32 = @floatFromInt(clip.node);
    for (insts) |inst| {
        var out = inst;
        out.clip_node = clip_node;
        self.instances.appendAssumeCapacity(out);
    }
    self.layer_cmds.items[range.start + range.len - 1].count += @intCast(insts.len);
}

pub fn pushText(self: *DrawList, verts: []const gpu.SlugVertex, indices: []const u32, clip: Clip.State) !void {
    if (verts.len == 0 or indices.len == 0) return;
    if (!self.lastCmdMatches(.text, null, clip)) {
        try self.beginCommand(.text, null, clip, @intCast(self.text_indices.items.len));
    }

    const range = self.layer_ranges[self.current_layer];
    const vertex_base: u32 = @intCast(self.text_vertices.items.len);
    try self.text_indices.ensureUnusedCapacity(self.allocator, indices.len);
    for (indices) |idx| {
        self.text_indices.appendAssumeCapacity(idx + vertex_base);
    }
    try self.text_vertices.ensureUnusedCapacity(self.allocator, verts.len);
    const clip_node: f32 = @floatFromInt(clip.node);
    for (verts) |v| {
        var out = v;
        out.clip_node = clip_node;
        self.text_vertices.appendAssumeCapacity(out);
    }
    self.layer_cmds.items[range.start + range.len - 1].count += @intCast(indices.len);
}

pub fn beginTextBatch(self: *DrawList, max_quads: usize, clip: Clip.State) !?TextBatch {
    if (max_quads == 0) return null;
    try self.text_vertices.ensureUnusedCapacity(self.allocator, max_quads * 4);
    try self.text_indices.ensureUnusedCapacity(self.allocator, max_quads * 6);
    return .{ .clip = clip };
}

pub fn pushTextQuad(self: *DrawList, batch: TextBatch, verts: [4]gpu.SlugVertex) !void {
    if (!self.lastCmdMatches(.text, null, batch.clip)) {
        try self.beginCommand(.text, null, batch.clip, @intCast(self.text_indices.items.len));
    }

    const range = self.layer_ranges[self.current_layer];
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
    self.layer_cmds.items[range.start + range.len - 1].count += 6;
}
