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
/// Packet streams in batched draw order; `vertices` is shared unchanged.
packet_indices: std.ArrayList(u32),
packet_instances: std.ArrayList(types.Instance),
packet_text_instances: std.ArrayList(types.SlugInstance),
/// Layers whose data is in the packet streams since the last reset.
packet_layers: std.StaticBitSet(MAX_LAYERS),
batch_entries: std.ArrayList(BatchEntry),
batch_keys: std.ArrayList(BatchKey),
batch_links: std.ArrayList(BatchLink),
batch_sorted: std.ArrayList(BatchEntry),
batch_counts: std.ArrayList(u32),

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
        .packet_indices = .empty,
        .packet_instances = .empty,
        .packet_text_instances = .empty,
        .packet_layers = .empty,
        .batch_entries = .empty,
        .batch_keys = .empty,
        .batch_links = .empty,
        .batch_sorted = .empty,
        .batch_counts = .empty,
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
    self.packet_indices.deinit(self.allocator);
    self.packet_instances.deinit(self.allocator);
    self.packet_text_instances.deinit(self.allocator);
    self.batch_entries.deinit(self.allocator);
    self.batch_keys.deinit(self.allocator);
    self.batch_links.deinit(self.allocator);
    self.batch_sorted.deinit(self.allocator);
    self.batch_counts.deinit(self.allocator);
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
    self.clearPacketStreams();
}

fn clearPacketStreams(self: *DrawList) void {
    self.packet_indices.clearRetainingCapacity();
    self.packet_instances.clearRetainingCapacity();
    self.packet_text_instances.clearRetainingCapacity();
    self.packet_layers = .empty;
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
    self: *DrawList,
    portable_commands: *std.ArrayList(Command),
    glyph_atlas: ?GlyphAtlas,
) !Packet {
    return self.buildPacketRange(portable_commands, glyph_atlas, 0, MAX_LAYERS);
}

/// Flatten one bounded half-open layer range into draw order, batching draws
/// that share a pipeline and texture where painter's order allows it.
/// Packets built from disjoint layer ranges stay valid together until reset;
/// building an overlapping range invalidates earlier packets.
pub fn buildPacketRange(
    self: *DrawList,
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

    var range_layers: std.StaticBitSet(MAX_LAYERS) = .empty;
    range_layers.setRangeValue(.{ .start = layer_min, .end = layer_max }, true);
    if (self.packet_layers.intersectWith(range_layers).count() > 0) self.clearPacketStreams();
    self.packet_layers.setUnion(range_layers);
    // Disjoint ranges together copy at most every element once, so earlier
    // packets' slices survive later builds.
    try self.packet_indices.ensureTotalCapacity(self.allocator, self.indices.items.len);
    try self.packet_instances.ensureTotalCapacity(self.allocator, self.instances.items.len);
    try self.packet_text_instances.ensureTotalCapacity(self.allocator, self.text_instances.items.len);

    var layer = layer_min;
    while (layer < layer_max) : (layer += 1) {
        if (!self.layers_dirty.isSet(layer)) continue;
        const range = self.layer_ranges[layer];
        const start: usize = range.start;
        const end = start + range.len;
        if (end > self.layer_cmds.items.len) return error.CorruptDrawStream;

        const layer_commands = self.layer_cmds.items[start..end];
        for (layer_commands) |command| switch (command.payload) {
            .vertex => |draw| try validateRange(draw.offset, draw.count, self.indices.items.len),
            .instance => |draw| try validateRange(draw.offset, draw.count, self.instances.items.len),
            .text => |draw| try validateRange(draw.offset, draw.count, self.text_instances.items.len),
            .custom_draw, .backdrop => {},
        };

        // Custom draws and backdrops are barriers; batch the runs between them.
        var segment_start: usize = 0;
        for (layer_commands, 0..) |command, index| switch (command.payload) {
            .custom_draw, .backdrop => {
                try self.emitBatched(portable_commands, layer_commands[segment_start..index]);
                portable_commands.appendAssumeCapacity(command);
                segment_start = index + 1;
            },
            else => {},
        };
        try self.emitBatched(portable_commands, layer_commands[segment_start..]);
    }

    return .init(
        portable_commands.items,
        self.vertices.items,
        self.packet_indices.items,
        self.packet_instances.items,
        self.packet_text_instances.items,
        self.clip_nodes.items,
        glyph_atlas,
    );
}

const BatchKey = struct {
    command: Command,
    /// Highest level assigned to the key so far.
    level: u32 = 0,
};

const BatchEntry = struct {
    command: u32,
    key: u32,
    level: u32,
    bounds: Box,
};

/// Min/max corners in logical pixels.
const Box = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    const empty: Box = .{ .x0 = std.math.inf(f32), .y0 = std.math.inf(f32), .x1 = -std.math.inf(f32), .y1 = -std.math.inf(f32) };

    fn add(self: *Box, x: f32, y: f32) void {
        self.x0 = @min(self.x0, x);
        self.y0 = @min(self.y0, y);
        self.x1 = @max(self.x1, x);
        self.y1 = @max(self.y1, y);
    }

    fn merge(self: *Box, other: Box) void {
        self.add(other.x0, other.y0);
        self.add(other.x1, other.y1);
    }

    fn overlaps(self: Box, other: Box) bool {
        return self.x0 < other.x1 and other.x0 < self.x1 and self.y0 < other.y1 and other.y0 < self.y1;
    }

    fn isFinite(self: Box) bool {
        return std.math.isFinite(self.x0) and std.math.isFinite(self.y0) and
            std.math.isFinite(self.x1) and std.math.isFinite(self.y1) and
            self.x0 <= self.x1 and self.y0 <= self.y1;
    }
};

const grid_axis_max = 64;
const grid_cells_max = grid_axis_max * grid_axis_max;
const batch_keys_max = 256;
/// Covers antialiasing fringes and glyph dilation.
const bounds_padding: f32 = 2;

const BatchLink = struct { entry: u32, next: u32 };
const no_link = std.math.maxInt(u32);

/// Reorder one barrier-free run so commands sharing a pipeline, texture and
/// scissor draw together. Each command gets the lowest level above every
/// earlier overlapping command of another key, and no lower than earlier
/// overlapping commands of its own key; drawing by level keeps every
/// overlapping pair in its original order.
fn emitBatched(self: *DrawList, out: *std.ArrayList(Command), commands: []const Command) !void {
    if (commands.len == 0) return;
    self.batch_entries.clearRetainingCapacity();
    self.batch_keys.clearRetainingCapacity();
    try self.batch_entries.ensureTotalCapacity(self.allocator, commands.len);

    var union_box: Box = .empty;
    var key_end: u32 = 0;
    var extent_sum: [2]f32 = .{ 0, 0 };
    var finite_count: u32 = 0;
    for (commands, 0..) |command, index| {
        const bounds = self.commandBounds(command);
        if (bounds.isFinite()) {
            union_box.merge(bounds);
            extent_sum[0] += bounds.x1 - bounds.x0;
            extent_sum[1] += bounds.y1 - bounds.y0;
            finite_count += 1;
        }
        self.batch_entries.appendAssumeCapacity(.{
            .command = @intCast(index),
            .key = try self.batchKey(command),
            .level = 0,
            .bounds = bounds,
        });
        key_end = @max(key_end, self.batch_entries.items[index].key + 1);
    }
    if (!union_box.isFinite()) union_box = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 };
    // Unknown bounds overlap everything.
    for (self.batch_entries.items) |*entry| {
        if (!entry.bounds.isFinite()) entry.bounds = union_box;
    }

    // Cells about the size of an average command keep buckets short.
    const union_w = @max(union_box.x1 - union_box.x0, 1e-3);
    const union_h = @max(union_box.y1 - union_box.y0, 1e-3);
    const count_f: f32 = @floatFromInt(@max(finite_count, 1));
    const cols = gridCells(union_w, extent_sum[0] / count_f);
    const rows = gridCells(union_h, extent_sum[1] / count_f);
    const cell_w = union_w / @as(f32, @floatFromInt(cols));
    const cell_h = union_h / @as(f32, @floatFromInt(rows));

    // Buckets of earlier entries per cell, as linked lists through `batch_links`.
    var heads_buffer: [grid_cells_max]u32 = undefined;
    const heads = heads_buffer[0 .. cols * rows];
    @memset(heads, no_link);
    self.batch_links.clearRetainingCapacity();
    const entries = self.batch_entries.items;
    var level_max: u32 = 0;
    for (entries, 0..) |*entry, entry_index| {
        const cx0 = gridCoord(entry.bounds.x0, union_box.x0, cell_w, cols);
        const cy0 = gridCoord(entry.bounds.y0, union_box.y0, cell_h, rows);
        const cx1 = gridCoord(entry.bounds.x1, union_box.x0, cell_w, cols);
        const cy1 = gridCoord(entry.bounds.y1, union_box.y0, cell_h, rows);
        // Any level at or above the minimum is valid; joining the key's latest
        // batch avoids opening a new draw.
        const tracked = entry.key < self.batch_keys.items.len;
        var level: u32 = if (tracked) self.batch_keys.items[entry.key].level else 0;
        for (cy0..cy1 + 1) |cy| for (cx0..cx1 + 1) |cx| {
            var link = heads[cy * cols + cx];
            while (link != no_link) : (link = self.batch_links.items[link].next) {
                const other = &entries[self.batch_links.items[link].entry];
                const needed = if (other.key == entry.key) other.level else other.level + 1;
                if (needed > level and entry.bounds.overlaps(other.bounds)) level = needed;
            }
        };
        if (tracked) self.batch_keys.items[entry.key].level = level;
        entry.level = level;
        level_max = @max(level_max, level);
        try self.batch_links.ensureUnusedCapacity(self.allocator, (cy1 - cy0 + 1) * (cx1 - cx0 + 1));
        for (cy0..cy1 + 1) |cy| for (cx0..cx1 + 1) |cx| {
            const head = &heads[cy * cols + cx];
            self.batch_links.appendAssumeCapacity(.{ .entry = @intCast(entry_index), .next = head.* });
            head.* = @intCast(self.batch_links.items.len - 1);
        };
    }

    try self.sortEntries(level_max, key_end);

    var index: usize = 0;
    while (index < self.batch_entries.items.len) {
        const first = self.batch_entries.items[index];
        var command = commands[first.command];
        switch (command.payload) {
            .vertex => |*draw| draw.offset = @intCast(self.packet_indices.items.len),
            .instance => |*draw| draw.offset = @intCast(self.packet_instances.items.len),
            .text => |*draw| draw.offset = @intCast(self.packet_text_instances.items.len),
            .custom_draw, .backdrop => unreachable,
        }
        var count: u32 = 0;
        while (index < self.batch_entries.items.len) : (index += 1) {
            const entry = self.batch_entries.items[index];
            if (entry.level != first.level or entry.key != first.key) break;
            switch (commands[entry.command].payload) {
                .vertex => |draw| self.packet_indices.appendSliceAssumeCapacity(self.indices.items[draw.offset..][0..draw.count]),
                .instance => |draw| self.packet_instances.appendSliceAssumeCapacity(self.instances.items[draw.offset..][0..draw.count]),
                .text => |draw| self.packet_text_instances.appendSliceAssumeCapacity(self.text_instances.items[draw.offset..][0..draw.count]),
                .custom_draw, .backdrop => unreachable,
            }
            count += switch (commands[entry.command].payload) {
                .vertex => |draw| draw.count,
                .instance => |draw| draw.count,
                .text => |draw| draw.count,
                .custom_draw, .backdrop => unreachable,
            };
        }
        switch (command.payload) {
            .vertex => |*draw| draw.count = count,
            .instance => |*draw| draw.count = count,
            .text => |*draw| draw.count = count,
            .custom_draw, .backdrop => unreachable,
        }
        out.appendAssumeCapacity(command);
    }
}

/// Stable order by (level, key, command): counting sorts by key, then level.
fn sortEntries(self: *DrawList, level_max: u32, key_end: u32) !void {
    const entries = self.batch_entries.items;
    try self.batch_sorted.resize(self.allocator, entries.len);
    try self.batch_counts.resize(self.allocator, @max(level_max + 1, key_end) + 1);
    countingSort(entries, self.batch_sorted.items, self.batch_counts.items[0 .. key_end + 1], "key");
    countingSort(self.batch_sorted.items, entries, self.batch_counts.items[0 .. level_max + 2], "level");
}

fn countingSort(from: []const BatchEntry, to: []BatchEntry, counts: []u32, comptime field: []const u8) void {
    @memset(counts, 0);
    for (from) |entry| counts[@field(entry, field) + 1] += 1;
    for (1..counts.len) |index| counts[index] += counts[index - 1];
    for (from) |entry| {
        const slot = &counts[@field(entry, field)];
        to[slot.*] = entry;
        slot.* += 1;
    }
}

fn gridCells(extent: f32, average: f32) usize {
    const cells = extent / @max(average, 1);
    if (!(cells > 1)) return 1;
    if (cells >= grid_axis_max) return grid_axis_max;
    return @intFromFloat(cells);
}

fn gridCoord(value: f32, origin: f32, cell: f32, cells: usize) usize {
    const coord = @floor((value - origin) / cell);
    if (!(coord > 0)) return 0;
    const last: f32 = @floatFromInt(cells - 1);
    if (coord >= last) return cells - 1;
    return @intFromFloat(coord);
}

/// Commands with equal keys can share one draw.
fn batchKey(self: *DrawList, command: Command) !u32 {
    for (self.batch_keys.items, 0..) |key, index| {
        if (self.keyMatches(key.command, command)) return @intCast(index);
    }
    // Past the bound, commands keep unique keys and simply do not merge.
    if (self.batch_keys.items.len == batch_keys_max) return @intCast(batch_keys_max + self.batch_entries.items.len);
    try self.batch_keys.append(self.allocator, .{ .command = command });
    return @intCast(self.batch_keys.items.len - 1);
}

fn keyMatches(_: *const DrawList, other: Command, command: Command) bool {
    if (std.meta.activeTag(other.payload) != std.meta.activeTag(command.payload)) return false;
    if (!other.clip.scissorEql(command.clip)) return false;
    return switch (command.payload) {
        .vertex => |draw| textureSourceEql(draw.texture, other.payload.vertex.texture),
        .instance => |draw| textureSourceEql(draw.texture, other.payload.instance.texture),
        .text => true,
        .custom_draw, .backdrop => unreachable,
    };
}

/// Conservative screen bounds of everything the command can touch.
fn commandBounds(self: *const DrawList, command: Command) Box {
    var box: Box = .empty;
    switch (command.payload) {
        .vertex => |draw| for (self.indices.items[draw.offset..][0..draw.count]) |vertex_index| {
            if (vertex_index >= self.vertices.items.len) return .empty;
            const vertex = self.vertices.items[vertex_index];
            box.add(vertex.pos[0], vertex.pos[1]);
        },
        .instance => |draw| for (self.instances.items[draw.offset..][0..draw.count]) |inst| {
            box.add(inst.pos[0], inst.pos[1]);
            box.add(inst.pos[0] + inst.size[0], inst.pos[1] + inst.size[1]);
        },
        .text => |draw| for (self.text_instances.items[draw.offset..][0..draw.count]) |inst| {
            const size = inst.origin_size[2];
            box.add(inst.origin_size[0] + inst.bounds[0] * size, inst.origin_size[1] - inst.bounds[1] * size);
            box.add(inst.origin_size[0] + inst.bounds[2] * size, inst.origin_size[1] - inst.bounds[3] * size);
        },
        .custom_draw, .backdrop => unreachable,
    }
    if (!box.isFinite()) return .empty;
    box.x0 -= bounds_padding;
    box.y0 -= bounds_padding;
    box.x1 += bounds_padding;
    box.y1 += bounds_padding;
    if (command.clip.scissor) |scissor| {
        box.x0 = @max(box.x0, scissor.x());
        box.y0 = @max(box.y0, scissor.y());
        box.x1 = @min(box.x1, scissor.x() + scissor.w());
        box.y1 = @min(box.y1, scissor.y() + scissor.h());
        // Fully scissored away: draws nothing, so it overlaps nothing.
        if (box.x0 > box.x1 or box.y0 > box.y1) return .{ .x0 = box.x0, .y0 = box.y0, .x1 = box.x0, .y1 = box.y0 };
    }
    return box;
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

fn testRect(x: f32, y: f32, w: f32, h: f32) types.Instance {
    var inst = std.mem.zeroes(types.Instance);
    inst.pos = .{ x, y };
    inst.size = .{ w, h };
    return inst;
}

fn testGlyph(x: f32, y: f32) types.SlugInstance {
    var inst = std.mem.zeroes(types.SlugInstance);
    // Em box 0..1 at 10px: covers x..x+10, y-10..y.
    inst.bounds = .{ 0, 0, 1, 1 };
    inst.origin_size = .{ x, y, 10, 0.1 };
    return inst;
}

fn testPushGlyph(draw_list: *DrawList, x: f32, y: f32) !void {
    const batch = (try draw_list.beginTextBatch(1, .{})).?;
    try draw_list.pushTextInstance(batch, testGlyph(x, y));
}

test "disjoint widgets batch into one draw per pipeline" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    var packet_commands: std.ArrayList(Command) = .empty;
    defer packet_commands.deinit(std.testing.allocator);

    var row: f32 = 0;
    while (row < 100) : (row += 1) {
        try draw_list.pushInstances(&.{testRect(0, row * 40, 100, 30)}, .atlas, .{});
        try testPushGlyph(&draw_list, 10, row * 40 + 20);
    }
    const packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expectEqual(@as(usize, 2), packet.commands().len);
    try std.testing.expect(packet.commands()[0].payload == .instance);
    try std.testing.expectEqual(@as(u32, 100), packet.commands()[0].payload.instance.count);
    try std.testing.expectEqual(@as(u32, 100), packet.commands()[1].payload.text.count);
    try std.testing.expectEqual(@as(f32, 99 * 40), packet.instances()[99].pos[1]);
}

test "overlapping draws keep painter's order" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    var packet_commands: std.ArrayList(Command) = .empty;
    defer packet_commands.deinit(std.testing.allocator);

    // Rect, glyph on it, rect over the glyph, and a disjoint rect.
    try draw_list.pushInstances(&.{testRect(0, 0, 50, 50)}, .atlas, .{});
    try testPushGlyph(&draw_list, 10, 20);
    try draw_list.pushInstances(&.{testRect(5, 5, 20, 20)}, .atlas, .{});
    try testPushGlyph(&draw_list, 200, 220);
    try draw_list.pushInstances(&.{testRect(300, 300, 10, 10)}, .atlas, .{});

    const packet = try draw_list.buildPacket(&packet_commands, null);
    const commands = packet.commands();
    try std.testing.expectEqual(@as(usize, 3), commands.len);
    // The base rect, both glyphs, then both later rects above the first glyph.
    try std.testing.expectEqual(@as(u32, 1), commands[0].payload.instance.count);
    try std.testing.expectEqual(@as(u32, 2), commands[1].payload.text.count);
    try std.testing.expectEqual(@as(u32, 2), commands[2].payload.instance.count);
    try std.testing.expectEqual(@as(f32, 5), packet.instances()[commands[2].payload.instance.offset].pos[0]);
}

test "custom draws stay barriers" {
    var draw_list = DrawList.init(std.testing.allocator);
    defer draw_list.deinit();
    var packet_commands: std.ArrayList(Command) = .empty;
    defer packet_commands.deinit(std.testing.allocator);

    try draw_list.pushInstances(&.{testRect(0, 0, 10, 10)}, .atlas, .{});
    try draw_list.pushCustomDraw(&.{ .extension = .knots, .callback = testDrawCallback, .user_data = null }, .zero, .{});
    try draw_list.pushInstances(&.{testRect(100, 100, 10, 10)}, .atlas, .{});
    const packet = try draw_list.buildPacket(&packet_commands, null);
    try std.testing.expectEqual(@as(usize, 3), packet.commands().len);
    try std.testing.expect(packet.commands()[1].payload == .custom_draw);
}

fn testDrawCallback(_: ?*anyopaque, _: *anyopaque) !void {}
