const std = @import("std");
const gpu = @import("gpu");
const math = @import("math");
const Clip = @import("Clip.zig");
const Texture = @import("Texture.zig");
const DrawCallback = @import("gpu.zig").DrawCallback;

pub const MAX_LAYERS = 256;

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
        texture: ?*const Texture,
        offset: u32,
        count: u32,
    };

    pub const Instanced = struct {
        texture: ?*const Texture,
        offset: u32,
        count: u32,
    };

    pub const Text = struct {
        offset: u32,
        count: u32,
    };

    pub const CustomDraw = struct {
        callback: DrawCallback,
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

fn lastCmdMatches(self: *const DrawList, kind: Command.Kind, texture: ?*const Texture, clip: Clip.State) bool {
    if (!self.layers_dirty.isSet(self.current_layer)) return false;
    const range = self.layer_ranges[self.current_layer];
    if (range.len == 0) return false;
    const last = self.layer_cmds.items[range.start + range.len - 1];
    if (std.meta.activeTag(last.payload) != kind or !last.clip.scissorEql(clip)) return false;
    return switch (last.payload) {
        .vertex => |cmd| cmd.texture == texture,
        .instance => |cmd| cmd.texture == texture,
        .text => texture == null,
        .custom_draw => false,
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

pub fn push(self: *DrawList, vertices: []const gpu.Vertex, indices: []const u32, texture: ?*const Texture, clip: Clip.State) !void {
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

pub fn pushInstances(self: *DrawList, insts: []const gpu.Instance, texture: ?*const Texture, clip: Clip.State) !void {
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

pub fn pushCustomDraw(self: *DrawList, callback: DrawCallback, user_data: ?*anyopaque, bounds: math.Rect, clip: Clip.State) !void {
    try self.beginCommand(.{ .custom_draw = .{
        .callback = callback,
        .user_data = user_data,
        .bounds = bounds,
    } }, clip);
}

pub fn pushText(self: *DrawList, verts: []const gpu.SlugVertex, indices: []const u32, clip: Clip.State) !void {
    if (verts.len == 0 or indices.len == 0) return;
    if (!self.lastCmdMatches(.text, null, clip)) {
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
    if (!self.lastCmdMatches(.text, null, batch.clip)) {
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
