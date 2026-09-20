const std = @import("std");
const input_types = @import("input");
const render = @import("render");
const text = @import("text");
const UI = @import("UI.zig");
const Frame = @import("Frame.zig");
const StateBridge = @import("StateBridge.zig");

const theme_state_key = StateBridge.key("knots.ui.theme");

pub const Config = struct {
    ui: UI.Config = .{},
    arena_reset_mode: std.heap.ArenaAllocator.ResetMode = .retain_capacity,
};

const Context = @This();

allocator: std.mem.Allocator,
frame_arena: std.heap.ArenaAllocator,
ui: UI,
draw_list: render.DrawList,
packet_commands: std.ArrayList(render.DrawList.Command),
overlay_commands: std.ArrayList(render.DrawList.Command),
state_bridge: StateBridge,
cfg: Config,
frame_input: input_types.FrameInput,
frame_state: ?Frame.State,
generation: u64,
atlas_id: u32,
glyph_revision_emitted: u64,
region_router: @import("Regions.zig").Router = .{},
region_identities: [Frame.modules_max]u64 = @splat(0),

pub fn init(allocator: std.mem.Allocator, cfg: Config) !Context {
    var ui = try UI.init(allocator, cfg.ui);
    errdefer ui.deinit();

    return .{
        .allocator = allocator,
        .frame_arena = .init(allocator),
        .ui = ui,
        .draw_list = .init(allocator),
        .packet_commands = .empty,
        .overlay_commands = .empty,
        .state_bridge = try .init(allocator),
        .cfg = cfg,
        .frame_input = undefined,
        .frame_state = null,
        .generation = 0,
        .atlas_id = render.GlyphAtlas.allocateId(),
        .glyph_revision_emitted = 0,
    };
}

pub fn deinit(self: *Context) void {
    std.debug.assert(!self.frameIsActive());
    self.packet_commands.deinit(self.allocator);
    self.overlay_commands.deinit(self.allocator);
    self.state_bridge.deinit();
    self.draw_list.deinit();
    self.ui.deinit();
    self.frame_arena.deinit();
    self.* = undefined;
}

/// Begin one embedded frame.
///
/// `input` and every slice it references are borrowed until `endFrame` or
/// `abortFrame`. Beginning another frame first returns `FrameAlreadyActive`.
pub fn beginFrame(self: *Context, input: input_types.FrameInput) !Frame {
    if (self.frameIsActive()) return error.FrameAlreadyActive;
    try validateInput(&input);

    if (self.generation == std.math.maxInt(u64)) return error.FrameGenerationExhausted;
    self.generation += 1;
    _ = self.frame_arena.reset(self.cfg.arena_reset_mode);
    self.packet_commands.clearRetainingCapacity();
    self.overlay_commands.clearRetainingCapacity();
    self.frame_input = input;
    if (try self.state_bridge.read(@import("Theme.zig"), theme_state_key)) |theme| {
        self.ui.theme = theme;
    } else {
        try self.state_bridge.write(@import("Theme.zig"), theme_state_key, self.ui.theme);
    }
    try self.ui.state.importBridge(&self.state_bridge);
    try self.ui.resolveWindow(input.input, input.now_ms, input.content_scale);
    self.ui.reset();
    self.frame_state = .init(
        &self.ui,
        self.frame_arena.allocator(),
        self.frame_arena.queryCapacity(),
        &self.frame_input,
        self.generation,
        &self.state_bridge,
    );

    return .{
        ._state = &self.frame_state.?,
        ._generation = self.generation,
    };
}

/// Finish one frame for every backend. Output is borrowed until the next
/// beginFrame attempt or Context.deinit; failure also releases the active frame.
pub fn endFrame(self: *Context, frame: *Frame) !Frame.Output {
    if (!self.frameIsActive()) return error.FrameNotActive;
    if (frame._state != &self.frame_state.?) return error.InvalidFrame;
    if (frame._generation != self.generation) return error.InvalidFrame;
    errdefer self.frame_state.?.active = false;
    try self.ui.endFrame();
    try self.ui.resolve();
    try frame.commitState();
    try self.state_bridge.write(@import("Theme.zig"), theme_state_key, self.ui.theme);
    self.draw_list.reset();
    try self.ui.tessellate(self.frame_arena.allocator(), &self.draw_list);
    const hover_changed = self.ui.resolveHit();
    try self.ui.state.exportBridge(&self.state_bridge);
    self.frame_state.?.active = false;
    const atlas = self.glyphAtlas();
    const packet = try self.draw_list.buildPacketRange(&self.packet_commands, atlas, 0, Frame.host_overlay_layer_min);
    const overlay_packet = try self.draw_list.buildPacketRange(&self.overlay_commands, atlas, Frame.host_overlay_layer_min, render.DrawList.MAX_LAYERS);
    const contribution_calls = self.frame_state.?.contribution_calls.items;
    var contribution_identities: [Frame.modules_max]u64 = undefined;
    for (contribution_calls, 0..) |entry, index| contribution_identities[index] = entry.identity;
    try self.state_bridge.retainSubscribers(contribution_identities[0..contribution_calls.len]);
    var rectangles: [Frame.modules_max]@import("math").Rect = undefined;
    for (contribution_calls, 0..) |entry, index| {
        if (self.region_identities[index] != entry.identity) self.region_router.replaced(index);
        self.region_identities[index] = entry.identity;
        const box = self.ui.layout_ctx.pool.get(entry.slot).box;
        rectangles[index] = if (self.ui.slot_clips.items[entry.slot].scissor) |clip| box.intersect(clip) else box;
    }
    var routing_input = self.frame_input.input;
    const pointer_position: @import("math").Vec2 = .{ @floatCast(routing_input.pos[0]), @floatCast(routing_input.pos[1]) };
    if (self.ui.hitLayerAt(pointer_position)) |layer| {
        if (layer.index() >= Frame.host_overlay_layer_min) routing_input.pos = .{ -1_000_000, -1_000_000 };
    }
    try self.region_router.begin(rectangles[0..contribution_calls.len], &routing_input);
    defer self.region_router.finish(&self.frame_input.input);
    var contributions: std.ArrayList(Frame.Contribution) = .empty;
    var contribution_capture_pointer = false;
    var contribution_capture_keyboard = false;
    for (contribution_calls, 0..) |entry, index| {
        if (rectangles[index].isEmpty()) continue;
        const box = self.ui.layout_ctx.pool.get(entry.slot).box;
        const request = self.region_router.route(index, box, &self.frame_input);
        const state = try self.state_bridge.values(self.frame_arena.allocator());
        const child = try entry.render(entry.context, &request, state, box, self.frame_arena.allocator());
        try self.applyState(child.state);
        try self.state_bridge.replaceDependencies(entry.subscriber, child.dependencies);
        try self.state_bridge.clearDirty(entry.subscriber);
        try contributions.append(self.frame_arena.allocator(), .{
            .identity = entry.identity,
            .packet = try endFrameClip(self.frame_arena.allocator(), &child.packet, self.ui.slot_clips.items[entry.slot], self.ui.clip_nodes.items),
        });
        if (child.redraw) self.frame_state.?.effects.redraw = true;
        if (child.close) self.frame_state.?.effects.close = true;
        if (self.region_router.focused == index) {
            if (child.clipboard_write) |value| self.frame_state.?.effects.clipboard_write = value;
            if (child.text_input) self.ui.text_input_requested = true;
            if (child.capture_keyboard) contribution_capture_keyboard = true;
        }
        if (self.region_router.hovered == index) {
            self.ui.cursor_shape = child.cursor_shape;
            if (child.capture_pointer) contribution_capture_pointer = true;
        }
    }
    return .{
        .contributions = contributions.items,
        .packet = packet,
        .host_overlay = if (overlay_packet.commands().len > 0) overlay_packet else null,
        .cursor_shape = self.ui.cursor_shape,
        .capture_pointer = self.ui.state.hovered != UI.INVALID_ID or contribution_capture_pointer,
        .capture_keyboard = self.ui.state.focused != UI.INVALID_ID or contribution_capture_keyboard,
        .text_input = self.ui.text_input_requested,
        .redraw = self.frame_state.?.effects.redraw or hover_changed or
            self.ui.anim_active,
        .close = self.frame_state.?.effects.close,
        .clipboard_write = self.frame_state.?.effects.clipboard_write,
        .state = &.{},
    };
}

pub fn loadState(self: *Context, values: []const StateBridge.Value) !void {
    std.debug.assert(!self.frameIsActive());
    try self.state_bridge.load(values);
}

pub fn setStateScope(self: *Context, scope: u64) void {
    std.debug.assert(!self.frameIsActive());
    self.state_bridge.setScope(scope);
}

pub fn stateValues(self: *Context) ![]StateBridge.Value {
    std.debug.assert(!self.frameIsActive());
    return self.state_bridge.values(self.frame_arena.allocator());
}

pub fn beginDependencyCollection(self: *Context) void {
    self.state_bridge.beginDependencyCollection();
}

pub fn cancelDependencyCollection(self: *Context) void {
    self.state_bridge.cancelDependencyCollection();
}

pub fn endDependencyCollection(self: *Context) []const StateBridge.Dependency {
    std.debug.assert(self.frameIsActive());
    return self.state_bridge.endDependencyCollection();
}

pub fn applyState(self: *Context, values: []const StateBridge.Value) !void {
    try self.state_bridge.load(values);
    if (try self.state_bridge.read(@import("Theme.zig"), theme_state_key)) |theme| self.ui.theme = theme;
}

// Child geometry is already placed. Extend its clip ancestry with the parent's
// clip tree, preserving rounded clipping as well as the rectangular scissor.
fn endFrameClip(allocator: std.mem.Allocator, packet: *const render.Packet, parent: render.Clip.State, parent_nodes: []const render.Clip.Node) !render.Packet {
    std.debug.assert(parent_nodes.len > 0);
    std.debug.assert(parent.node < parent_nodes.len);
    const child_nodes = packet.clipNodes();
    const offset: u32 = @intCast(child_nodes.len);
    const nodes = try allocator.alloc(render.Clip.Node, child_nodes.len + parent_nodes.len);
    @memcpy(nodes[0..child_nodes.len], child_nodes);
    @memcpy(nodes[child_nodes.len..], parent_nodes);
    for (nodes[child_nodes.len..]) |*node| {
        if (node.parent != 0) node.parent += offset;
    }
    for (nodes[0..child_nodes.len], 0..) |*node, index| {
        if (index == 0) continue;
        if (node.parent == 0) {
            if (parent.node != 0) node.parent = parent.node + offset;
        }
    }
    const commands = try allocator.dupe(render.Command, packet.commands());
    for (commands) |*command| {
        if (parent.scissor) |scissor| {
            command.clip.scissor = if (command.clip.scissor) |child| child.intersect(scissor) else scissor;
        }
        if (command.clip.node == 0) {
            if (parent.node != 0) command.clip.node = parent.node + offset;
        }
        if (render.Clip.depth(nodes, command.clip.node) >= render.Clip.MAX_DEPTH) return error.ClipStackTooDeep;
    }
    const vertices = try allocator.dupe(render.types.Vertex, packet.primitiveVertices());
    const instances = try allocator.dupe(render.types.Instance, packet.instances());
    const texts = try allocator.dupe(render.types.SlugInstance, packet.textInstances());
    if (parent.node != 0) {
        const root: f32 = @floatFromInt(parent.node + offset);
        for (vertices) |*vertex| {
            if (vertex.clip_node == 0) vertex.clip_node = root;
        }
        for (instances) |*instance| {
            if (instance.clip_node == 0) instance.clip_node = root;
        }
        for (texts) |*glyph| {
            if (glyph.clip_node == 0) glyph.clip_node = root;
        }
    }
    return .init(commands, vertices, packet.primitiveIndices(), instances, texts, nodes, packet.glyphAtlas());
}

/// Cancel an active frame after user code fails, allowing a later retry.
/// Aborting an already-finished frame returns `error.FrameNotActive`.
pub fn abortFrame(self: *Context, frame: *Frame) !void {
    if (!self.frameIsActive()) return error.FrameNotActive;
    if (frame._state != &self.frame_state.?) return error.InvalidFrame;
    if (frame._generation != self.generation) return error.InvalidFrame;
    self.frame_state.?.active = false;
}

fn frameIsActive(self: *const Context) bool {
    const frame_state = self.frame_state orelse return false;
    return frame_state.active;
}

fn glyphAtlas(self: *Context) render.GlyphAtlas {
    const builder = self.ui.font.glyph_builder;
    comptime {
        std.debug.assert(text.GlyphBuilder.texture_width == render.GlyphAtlas.width);
        std.debug.assert(@sizeOf(text.GlyphBuilder.CurveTexel) == render.GlyphAtlas.texel_bytes);
        std.debug.assert(@sizeOf(text.GlyphBuilder.BandTexel) == render.GlyphAtlas.texel_bytes);
    }
    const atlas: render.GlyphAtlas = .{
        .id = self.atlas_id,
        .revision = builder.revision(),
        .base_revision = self.glyph_revision_emitted,
        .curve_row_start = if (builder.curveDirtyRange()) |range| range.y_start else builder.curveTextureHeight(),
        .band_row_start = if (builder.bandDirtyRange()) |range| range.y_start else builder.bandTextureHeight(),
        .curve = std.mem.sliceAsBytes(builder.curve_data.items),
        .band = std.mem.sliceAsBytes(builder.band_data.items),
    };
    atlas.validate();
    // A missed output is safe: consumers with an older revision use full data.
    self.glyph_revision_emitted = atlas.revision;
    builder.markClean();
    return atlas;
}

fn validateInput(input: *const input_types.FrameInput) !void {
    if (input.logical_extent.width == 0) return error.InvalidFrameExtent;
    if (input.logical_extent.height == 0) return error.InvalidFrameExtent;
    if (input.physical_extent.width == 0) return error.InvalidFrameExtent;
    if (input.physical_extent.height == 0) return error.InvalidFrameExtent;
    if (!std.math.isFinite(input.content_scale)) return error.InvalidContentScale;
    if (input.content_scale <= 0) return error.InvalidContentScale;
}

test "frame lifecycle rejects invalid ordering and supports abort" {
    var view = try Context.init(std.testing.allocator, .{});
    defer view.deinit();

    const input: input_types.FrameInput = .{
        .input = .{ .pos = .{ 0, 0 } },
        .now_ms = 0,
        .delta_ns = 0,
        .logical_extent = .{ .width = 10, .height = 10 },
        .physical_extent = .{ .width = 10, .height = 10 },
        .content_scale = 1,
    };
    var frame = try view.beginFrame(input);
    try view.abortFrame(&frame);
    try std.testing.expectError(error.FrameNotActive, view.abortFrame(&frame));
    frame = try view.beginFrame(input);
    _ = try view.endFrame(&frame);
    try std.testing.expectError(error.FrameNotActive, view.endFrame(&frame));
}

test "frame carries host input, effects, and retryable glyph data" {
    var view = try Context.init(std.testing.allocator, .{});
    defer view.deinit();

    const dropped = [_][]const u8{"asset.glb"};
    const input: input_types.FrameInput = .{
        .input = .{ .pos = .{ 2, 3 } },
        .now_ms = 12,
        .delta_ns = 16,
        .logical_extent = .{ .width = 100, .height = 50 },
        .physical_extent = .{ .width = 200, .height = 100 },
        .content_scale = 2,
        .paste_text = "paste",
        .dropped_paths = &dropped,
    };

    var frame = try view.beginFrame(input);
    try std.testing.expectEqualStrings("paste", frame.pasteText().?);
    try std.testing.expectEqualStrings("asset.glb", frame.droppedPaths()[0]);
    try std.testing.expectEqual(@as(u32, 200), frame.input().physical_extent.width);
    frame.requestRedraw();
    frame.requestClose();
    try frame.writeClipboard("copy");
    const first = try view.endFrame(&frame);
    try std.testing.expect(first.redraw);
    try std.testing.expect(first.close);
    try std.testing.expectEqualStrings("copy", first.clipboard_write.?);

    const glyph = first.packet.glyphAtlas().?;
    frame = try view.beginFrame(input);
    const second = try view.endFrame(&frame);
    try std.testing.expectEqual(glyph.id, second.packet.glyphAtlas().?.id);
    try std.testing.expectEqual(glyph.revision, second.packet.glyphAtlas().?.revision);
}

test "frame validates extents and scale" {
    var view = try Context.init(std.testing.allocator, .{});
    defer view.deinit();
    const base: input_types.FrameInput = .{
        .input = .{ .pos = .{ 0, 0 } },
        .now_ms = 0,
        .delta_ns = 0,
        .logical_extent = .{ .width = 0, .height = 1 },
        .physical_extent = .{ .width = 1, .height = 1 },
        .content_scale = 1,
    };
    try std.testing.expectError(error.InvalidFrameExtent, view.beginFrame(base));
    var invalid_scale = base;
    invalid_scale.logical_extent.width = 1;
    invalid_scale.content_scale = 0;
    try std.testing.expectError(error.InvalidContentScale, view.beginFrame(invalid_scale));
}

test "every finalization allocation failure releases the frame and permits retry" {
    const input: input_types.FrameInput = .{
        .input = .{ .pos = .{ 0, 0 } },
        .now_ms = 0,
        .delta_ns = 0,
        .logical_extent = .{ .width = 100, .height = 100 },
        .physical_extent = .{ .width = 100, .height = 100 },
        .content_scale = 1,
    };
    var completed = false;
    var failure_offset: u32 = 0;
    while (failure_offset < 64) : (failure_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = std.math.maxInt(usize),
            .resize_fail_index = std.math.maxInt(usize),
        });
        var view = try Context.init(failing.allocator(), .{});
        defer view.deinit();
        var frame = try view.beginFrame(input);
        defer frame.deinit();
        _ = try frame.ui().open(.src(@src()), .{
            .width = .fixed(40),
            .height = .fixed(40),
        }, .{ .rect = .{ .color = .{ 1, 0, 0, 1 } } });
        frame.ui().close();
        failing.fail_index = failing.alloc_index + failure_offset;
        failing.resize_fail_index = failing.resize_index;
        if (view.endFrame(&frame)) |_| {
            completed = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(!view.frameIsActive());
        }
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        var next = try view.beginFrame(input);
        defer next.deinit();
        _ = try view.endFrame(&next);
        if (completed) break;
    }
    try std.testing.expect(completed);
    try std.testing.expect(failure_offset > 0);
}

test "embedded regions run after layout and reject repeated instances" {
    const Callback = struct {
        calls: u32 = 0,
        pointer_routed: bool = false,
        child: Context,
        fn draw(pointer: *anyopaque, input: *const input_types.FrameInput, _: []const StateBridge.Value, rectangle: @import("math").Rect, _: std.mem.Allocator) !Frame.ModuleOutput {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            std.debug.assert(rectangle.w() == 120);
            std.debug.assert(input.logical_extent.height == 80);
            self.calls += 1;
            self.pointer_routed = input.input.pos[0] >= 0;
            var child_frame = try self.child.beginFrame(input.*);
            defer child_frame.deinit();
            try child_frame.e(@import("component/Rect.zig"){
                .key = .str("child"),
                .width = .fixed(120),
                .height = .fixed(80),
                .style = .{ .color = .primary },
            });
            const output = try self.child.endFrame(&child_frame);
            return .{
                .packet = output.packet,
                .cursor_shape = output.cursor_shape,
                .capture_pointer = output.capture_pointer,
                .capture_keyboard = output.capture_keyboard,
                .text_input = output.text_input,
                .redraw = output.redraw,
                .close = output.close,
                .clipboard_write = output.clipboard_write,
                .state = output.state,
            };
        }
    };
    var callback: Callback = .{ .child = try .init(std.testing.allocator, .{}) };
    defer callback.child.deinit();
    var parent = try Context.init(std.testing.allocator, .{});
    defer parent.deinit();
    var frame = try parent.beginFrame(.{
        .input = .{ .pos = .{ 0, 0 } },
        .now_ms = 0,
        .delta_ns = 0,
        .logical_extent = .{ .width = 120, .height = 80 },
        .physical_extent = .{ .width = 120, .height = 80 },
        .content_scale = 1,
    });
    defer frame.deinit();
    const root: @import("component/Rect.zig") = .{ .key = .str("parent"), .width = .fixed(120), .height = .fixed(80) };
    _ = try root.open(&frame);
    try frame.contribute(.str("region"), 1, &callback, Callback.draw);
    try std.testing.expectError(error.RepeatedModule, frame.contribute(.str("duplicate"), 1, &callback, Callback.draw));
    try root.close(&frame);
    _ = try frame.ui().openRoot(.str("host.overlay"), 0, 0, .{
        .width = .fixed(120),
        .height = .fixed(80),
        .interactive = true,
        .z_index = Frame.host_overlay_layer_min,
    }, .{ .rect = .{ .color = .{ 0, 0, 0, 1 } } });
    frame.ui().close();
    try std.testing.expectEqual(@as(u32, 0), callback.calls);
    const output = try parent.endFrame(&frame);
    try std.testing.expectEqual(@as(u32, 1), callback.calls);
    try std.testing.expect(!callback.pointer_routed);
    try std.testing.expectEqual(@as(usize, 1), output.contributions.len);
    try std.testing.expectEqual(@as(u64, 1), output.contributions[0].identity);
    try std.testing.expect(output.host_overlay != null);
}

test "typed frame state is owned by the context across frames" {
    var context = try Context.init(std.testing.allocator, .{});
    defer context.deinit();
    const input: input_types.FrameInput = .{
        .input = .{ .pos = .{ -1, -1 } },
        .now_ms = 0,
        .delta_ns = 0,
        .logical_extent = .{ .width = 100, .height = 100 },
        .physical_extent = .{ .width = 100, .height = 100 },
        .content_scale = 1,
    };

    var first = try context.beginFrame(input);
    defer first.deinit();
    const first_value = try first.bindState(u32, "test.counter", 1);
    first_value.* = 9;
    _ = try context.endFrame(&first);

    var second = try context.beginFrame(input);
    defer second.deinit();
    const second_value = try second.bindState(u32, "test.counter", 1);
    try std.testing.expectEqual(@as(u32, 9), second_value.*);
    try std.testing.expect(second_value == try second.bindState(u32, "test.counter", 1));
    _ = try context.endFrame(&second);
}

test "widget state snapshot survives executor replacement" {
    const input: input_types.FrameInput = .{
        .input = .{ .pos = .{ -1, -1 } },
        .now_ms = 0,
        .delta_ns = 0,
        .logical_extent = .{ .width = 100, .height = 100 },
        .physical_extent = .{ .width = 100, .height = 100 },
        .content_scale = 1,
    };
    const widget_id: u64 = 42;

    var source = try Context.init(std.testing.allocator, .{});
    defer source.deinit();
    var source_frame = try source.beginFrame(input);
    defer source_frame.deinit();
    const scroll = try source_frame.ui().state.getOrCreate(.scroll, source_frame.ui().allocator, widget_id);
    scroll.offset = .{ 12, 34 };
    _ = try source.endFrame(&source_frame);
    const snapshot = try source.stateValues();

    var replacement = try Context.init(std.testing.allocator, .{});
    defer replacement.deinit();
    try replacement.loadState(snapshot);
    var replacement_frame = try replacement.beginFrame(input);
    defer replacement_frame.deinit();
    const restored = replacement_frame.ui().state.get(.scroll, widget_id).?;
    try std.testing.expectEqual(@as(f32, 12), restored.offset[0]);
    try std.testing.expectEqual(@as(f32, 34), restored.offset[1]);
    _ = try replacement.endFrame(&replacement_frame);
}
