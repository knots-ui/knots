const std = @import("std");
const gpu = @import("gpu");

pub const CommandKind = enum { vertex, instance };

pub const Command = struct {
    kind: CommandKind,
    texture: ?u32,
    // .vertex   -> offset/count are index_offset/index_count into `indices`
    // .instance -> offset/count are first_instance/instance_count into `instances`
    offset: u32,
    count: u32,
    clip_rect: ?[4]f32,
};

const LayerRange = struct { start: u32 = 0, len: u32 = 0 };

allocator: std.mem.Allocator,
vertices: std.ArrayList(gpu.Vertex),
indices: std.ArrayList(u32),
instances: std.ArrayList(gpu.Instance),
cmds: std.ArrayList(Command),
layer_cmds: std.ArrayList(Command),
layer_ranges: [256]LayerRange,
layers_dirty: std.StaticBitSet(256),
current_layer: u8,

const DrawList = @This();

pub fn init(allocator: std.mem.Allocator) DrawList {
    return DrawList{
        .allocator = allocator,
        .cmds = .empty,
        .indices = .empty,
        .vertices = .empty,
        .instances = .empty,
        .layer_cmds = .empty,
        .layer_ranges = [_]LayerRange{.{}} ** 256,
        .layers_dirty = .initEmpty(),
        .current_layer = 0,
    };
}

pub fn deinit(self: *DrawList) void {
    self.vertices.deinit(self.allocator);
    self.indices.deinit(self.allocator);
    self.instances.deinit(self.allocator);
    self.cmds.deinit(self.allocator);
    self.layer_cmds.deinit(self.allocator);
}

pub fn reset(self: *DrawList) void {
    self.vertices.clearRetainingCapacity();
    self.indices.clearRetainingCapacity();
    self.instances.clearRetainingCapacity();
    self.cmds.clearRetainingCapacity();
    self.layer_cmds.clearRetainingCapacity();
    var it = self.layers_dirty.iterator(.{});
    while (it.next()) |z| self.layer_ranges[z] = .{};
    self.layers_dirty = .initEmpty();
    self.current_layer = 0;
}

pub fn setLayer(self: *DrawList, layer: u8) void {
    self.current_layer = layer;
}

fn lastCmdMatches(self: *const DrawList, kind: CommandKind, texture: ?u32, clip: ?[4]f32) bool {
    const range = self.layer_ranges[self.current_layer];
    if (range.len == 0) return false;
    const last = &self.layer_cmds.items[range.start + range.len - 1];
    if (last.kind != kind) return false;
    if (last.texture != texture) return false;
    const a = last.clip_rect orelse return clip == null;
    const c = clip orelse return false;
    return std.mem.eql(f32, &a, &c);
}

fn beginCommand(self: *DrawList, kind: CommandKind, texture: ?u32, clip: ?[4]f32, offset: u32) !void {
    const range = &self.layer_ranges[self.current_layer];
    if (range.len == 0) {
        range.start = @intCast(self.layer_cmds.items.len);
        self.layers_dirty.set(self.current_layer);
    }
    try self.layer_cmds.append(self.allocator, .{
        .kind = kind,
        .texture = texture,
        .offset = offset,
        .count = 0,
        .clip_rect = clip,
    });
    range.len += 1;
}

pub fn push(self: *DrawList, vertices: []const gpu.Vertex, indices: []const u32, texture: ?u32, clip: ?[4]f32) !void {
    if (!self.lastCmdMatches(.vertex, texture, clip)) {
        try self.beginCommand(.vertex, texture, clip, @intCast(self.indices.items.len));
    }

    const range = self.layer_ranges[self.current_layer];
    const vertex_base: u32 = @intCast(self.vertices.items.len);
    try self.indices.ensureUnusedCapacity(self.allocator, indices.len);
    for (indices) |idx| {
        self.indices.appendAssumeCapacity(idx + vertex_base);
    }

    try self.vertices.appendSlice(self.allocator, vertices);
    self.layer_cmds.items[range.start + range.len - 1].count += @intCast(indices.len);
}

pub fn pushInstances(self: *DrawList, insts: []const gpu.Instance, texture: ?u32, clip: ?[4]f32) !void {
    if (insts.len == 0) return;
    if (!self.lastCmdMatches(.instance, texture, clip)) {
        const first_instance: u32 = @intCast(self.instances.items.len);
        try self.beginCommand(.instance, texture, clip, first_instance);
    }

    const range = self.layer_ranges[self.current_layer];
    try self.instances.appendSlice(self.allocator, insts);
    self.layer_cmds.items[range.start + range.len - 1].count += @intCast(insts.len);
}

pub fn finalize(self: *DrawList) !void {
    self.cmds.clearRetainingCapacity();
    try self.cmds.ensureTotalCapacity(self.allocator, self.layer_cmds.items.len);
    for (0..256) |z| {
        const range = self.layer_ranges[z];
        if (range.len == 0) continue;
        self.cmds.appendSliceAssumeCapacity(self.layer_cmds.items[range.start .. range.start + range.len]);
    }
}
