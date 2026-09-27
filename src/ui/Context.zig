const std = @import("std");
const input_types = @import("input");
const render = @import("render");
const text = @import("text");
const layout = @import("layout");
const math = @import("math");
const types = @import("render_types");
const style = @import("style");

const UI = @import("UI.zig");
const Frame = @import("Frame.zig");
const StateBridge = @import("StateBridge.zig");
const Accessibility = @import("Accessibility.zig");
const scrollbar = @import("scrollbar.zig");
const canvas_tessellator = @import("canvas_tessellator.zig");
const State = @import("State.zig");
const Decoration = @import("decoration.zig").Decoration;
const Key = @import("Key.zig");

const Clip = render.Clip;
const DrawList = render.DrawList;

const Layer = layout.Layer;
const Element = layout.Element;

const Radius = style.Radius;
const BorderWidth = style.BorderWidth;

const Allocator = std.mem.Allocator;
const HitRecord = UI.HitRecord;

const press_drag_threshold_sq: f64 = 9.0;

const theme_state_key = StateBridge.key("knots.ui.theme");

pub const Config = struct {
    ui: UI.Config = .{},
    arena_reset_mode: std.heap.ArenaAllocator.ResetMode = .retain_capacity,
    accessibility: bool = true,
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
accessibility_pending: std.ArrayList(Accessibility.ActionRequest) = .empty,
accessibility_frame: std.ArrayList(Accessibility.ActionRequest) = .empty,
semantic_revision: u64 = 0,
/// While unchanged, widget state already matches the bridge, so import is skipped.
bridge_synced_mutation: ?u64 = null,
semantic_digest: u64 = 0,

pub fn init(allocator: std.mem.Allocator, cfg: Config) !Context {
    var ui = try UI.init(allocator, cfg.ui);
    errdefer ui.deinit();
    ui.accessibility_enabled = cfg.accessibility;

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
    self.clearAccessibilityActions(&self.accessibility_pending);
    self.clearAccessibilityActions(&self.accessibility_frame);
    self.accessibility_pending.deinit(self.allocator);
    self.accessibility_frame.deinit(self.allocator);
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
    if (try self.state_bridge.read(@import("style").Theme, theme_state_key)) |theme| {
        self.ui.theme = theme;
    } else {
        try self.state_bridge.write(@import("style").Theme, theme_state_key, self.ui.theme);
    }
    if (self.bridge_synced_mutation != self.state_bridge.mutation) try self.ui.state.importBridge(&self.state_bridge);
    self.bridge_synced_mutation = null;
    try resolveWindow(&self.ui, input.input, input.now_ms, input.content_scale);
    const previous_nodes = self.ui.accessibility_nodes.items;
    var focused_action: ?@import("layout").Element.Id = null;
    for (self.accessibility_pending.items) |request| {
        if (request.action != .focus) continue;
        for (previous_nodes) |node| {
            if (node.id != request.id) continue;
            if (node.state.disabled) break;
            if (!node.actions.contains(.focus)) break;
            focused_action = request.id;
            break;
        }
    }
    reset(&self.ui);
    self.clearAccessibilityActions(&self.accessibility_frame);
    std.mem.swap(std.ArrayList(Accessibility.ActionRequest), &self.accessibility_frame, &self.accessibility_pending);
    self.ui.accessibility_actions = self.accessibility_frame.items;
    self.ui.accessibility_consumed = @splat(false);
    if (focused_action) |id| self.ui.state.focused = id;
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

/// The value is copied, so callers may release their action data on return.
pub fn enqueueAccessibilityAction(self: *Context, request: Accessibility.ActionRequest) !void {
    if (request.id == Accessibility.root_id or request.id == UI.INVALID_ID) return error.InvalidAccessibilityTarget;
    if (self.accessibility_pending.items.len == Accessibility.actions_max) return error.TooManyAccessibilityActions;
    var owned = request;
    if (request.value_text) |value| {
        if (value.len > Accessibility.text_bytes_max) return error.AccessibilityTextTooLong;
        _ = std.unicode.Utf8View.init(value) catch return error.InvalidAccessibilityText;
        owned.value_text = try self.allocator.dupe(u8, value);
    }
    errdefer if (owned.value_text) |value| self.allocator.free(value);
    try self.accessibility_pending.append(self.allocator, owned);
}

fn clearAccessibilityActions(self: *Context, actions: *std.ArrayList(Accessibility.ActionRequest)) void {
    for (actions.items) |request| if (request.value_text) |value| self.allocator.free(value);
    actions.clearRetainingCapacity();
}

/// Finish one frame for every backend. Output is borrowed until the next
/// beginFrame attempt or Context.deinit; failure also releases the active frame.
pub fn endFrame(self: *Context, frame: *Frame) !Frame.Output {
    if (!self.frameIsActive()) return error.FrameNotActive;
    if (frame._state != &self.frame_state.?) return error.InvalidFrame;
    if (frame._generation != self.generation) return error.InvalidFrame;
    errdefer self.frame_state.?.active = false;
    try endStateFrame(&self.ui);
    try resolve(&self.ui);
    const digest = if (self.cfg.accessibility) semanticDigest(semanticSnapshot(&self.ui)) else 0;
    if (self.semantic_revision == 0 or digest != self.semantic_digest) {
        if (self.semantic_revision == std.math.maxInt(u64)) return error.AccessibilityRevisionExhausted;
        self.semantic_revision += 1;
        self.semantic_digest = digest;
    }
    try frame.commitState();
    try self.state_bridge.write(@import("style").Theme, theme_state_key, self.ui.theme);
    self.draw_list.reset();
    try tessellate(&self.ui, self.frame_arena.allocator(), &self.draw_list);
    const hover_changed = resolveHit(&self.ui);
    try self.ui.state.exportBridge(&self.state_bridge);
    self.bridge_synced_mutation = self.state_bridge.mutation;
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
    if (hitLayerAt(&self.ui, pointer_position)) |layer| {
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
        .accessibility = blk: {
            var snapshot = semanticSnapshot(&self.ui);
            snapshot.revision = self.semantic_revision;
            break :blk snapshot;
        },
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

fn semanticDigest(snapshot: Accessibility.Snapshot) u64 {
    var digest = std.hash.Wyhash.init(0);
    digest.update(std.mem.asBytes(&snapshot.content_scale));
    digest.update(std.mem.asBytes(&snapshot.focus));
    for (snapshot.nodes) |node| {
        digest.update(std.mem.asBytes(&node.id));
        digest.update(std.mem.asBytes(&node.parent));
        hashOptional(&digest, node.text_run_id);
        digest.update(std.mem.asBytes(&node.role));
        const name_length: u32 = @intCast(node.name.len);
        digest.update(std.mem.asBytes(&name_length));
        digest.update(node.name);
        digest.update(std.mem.asBytes(&node.bounds.v));
        digest.update(std.mem.asBytes(&node.child_count));
        digest.update(std.mem.asBytes(&node.state.disabled));
        digest.update(std.mem.asBytes(&node.state.focused));
        digest.update(std.mem.asBytes(&node.state.multiline));
        hashOptional(&digest, node.state.checked);
        hashOptional(&digest, node.state.selected);
        hashOptional(&digest, node.state.expanded);
        const has_value_text = node.state.value_text != null;
        digest.update(std.mem.asBytes(&has_value_text));
        if (node.state.value_text) |value| {
            const length: u32 = @intCast(value.len);
            digest.update(std.mem.asBytes(&length));
            digest.update(value);
        }
        hashOptional(&digest, node.state.value_number);
        hashOptional(&digest, node.state.min);
        hashOptional(&digest, node.state.max);
        hashOptional(&digest, node.state.selection_anchor);
        hashOptional(&digest, node.state.selection_focus);
        const actions = node.actions.bits;
        digest.update(std.mem.asBytes(&actions));
    }
    digest.update(std.mem.sliceAsBytes(snapshot.children));
    return digest.final();
}

fn hashOptional(digest: *std.hash.Wyhash, value: anytype) void {
    const present = value != null;
    digest.update(std.mem.asBytes(&present));
    if (value) |item| digest.update(std.mem.asBytes(&item));
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
    if (try self.state_bridge.read(@import("style").Theme, theme_state_key)) |theme| self.ui.theme = theme;
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

fn reset(ui: *UI) void {
    ui.cull_depth = 0;
    ui.culled_count = 0;
    ui.layout_ctx.reset();
    ui.decorations.clearRetainingCapacity();
    ui.contents.clearRetainingCapacity();
    ui.clip_shapes.clearRetainingCapacity();
    ui.hit_records.clearRetainingCapacity();
    ui.focus_order.clearRetainingCapacity();
    Accessibility.freeNodes(ui.allocator, ui.accessibility_nodes.items);
    ui.accessibility_nodes.clearRetainingCapacity();
    ui.accessibility_children.clearRetainingCapacity();
    ui.accessibility_node_indices.clearRetainingCapacity();
    ui.hit_counter = 0;
    ui.scroll_geoms.clearRetainingCapacity();
    ui.slot_clips.clearRetainingCapacity();
    ui.child_clips.clearRetainingCapacity();
    ui.clip_nodes.clearRetainingCapacity();
    ui.input_scopes.resetFrame();
    ui.anim_active = false;
    ui.text_input_requested = false;
    ui.cursor_shape = .default;
}

fn resolve(ui: *UI) !void {
    if (ui.layout_ctx.root_slot == Element.INVALID_SLOT) {
        try ui.layout_ctx.buildZOrder();
        updateStats(ui);
        try syncAccessibility(ui);
        return;
    }

    const scroll: layout.Context.ScrollLookup = .{
        .ctx = @ptrCast(&ui.state),
        .getFn = @ptrCast(&State.getScroll),
    };

    ui.layout_ctx.computeSizes();
    try ui.layout_ctx.computeLayout(scroll, ui.theme.scrollbar_thickness);

    // After a first layout pass, recompute intrinsic_h for every wrap-text element using its just-assigned box width.
    if (try reflowWrappedText(ui)) {
        ui.layout_ctx.computeSizes();
        try ui.layout_ctx.computeLayout(scroll, ui.theme.scrollbar_thickness);
    }

    try ui.layout_ctx.buildZOrder();
    syncStateBounds(ui);
    try ui.recordCulling();
    try syncAccessibility(ui);
}

fn semanticSnapshot(ui: *const UI) Accessibility.Snapshot {
    const nodes = ui.accessibility_nodes.items;
    return .{
        .content_scale = ui.content_scale,
        .nodes = nodes,
        .children = ui.accessibility_children.items,
        .focus = if (ui.state.focused != Element.INVALID_ID and hasAccessibilityNode(ui, ui.state.focused)) ui.state.focused else Accessibility.root_id,
    };
}

fn hasAccessibilityNode(ui: *const UI, id: Element.Id) bool {
    return ui.accessibility_node_indices.contains(id);
}

/// Returns true if any height changed, in which case the caller should re-run layout so ancestors fit the new heights.
fn reflowWrappedText(ui: *UI) !bool {
    var changed = false;
    for (ui.decorations.items, 0..) |dec, slot| {
        if (dec != .text) continue;
        const t = dec.text;
        if (!t.wrap or t.content.len == 0) continue;

        const el = ui.layout_ctx.pool.get(@intCast(slot));
        const wrap_px = el.box.w() * ui.content_scale;
        if (wrap_px <= 0) continue;

        const face = try ui.font.getFace(t.font);
        const shaped = try face.shapeWrapped(t.content, t.size * ui.content_scale, wrap_px);
        const new_h = shaped.height / ui.content_scale;
        if (new_h != el.intrinsic_h) {
            el.intrinsic_h = new_h;
            changed = true;
        }
    }
    return changed;
}

fn syncStateBounds(ui: *UI) void {
    if (ui.layout_ctx.root_slot == Element.INVALID_SLOT) return;
    const root_box = ui.layout_ctx.pool.get(ui.layout_ctx.root_slot).box;
    for (ui.layout_ctx.pool.elements.items) |el| {
        if (ui.state.get(.text_select, el.id)) |s| s.box = el.box;
        if (ui.state.get(.slider, el.id)) |s| s.bounds = el.box;
        if (ui.state.get(.measured, el.id)) |s| {
            s.box = el.box;
            s.width = el.box.w();
            s.height = el.box.h();
        }
        if (ui.state.get(.resize, el.id)) |s| s.box = el.box;
        if (ui.state.get(.select_input, el.id)) |s| {
            s.anchor_box = el.box;
            s.viewport_box = root_box;
        }
        if (ui.state.get(.color_picker, el.id)) |s| {
            s.anchor_box = el.box;
            s.viewport_box = root_box;
        }
        if (ui.state.get(.context_menu, el.id)) |s| {
            s.anchor_box = el.box;
            s.viewport_box = root_box;
        }
        if (ui.state.get(.menu_button, el.id)) |s| {
            s.anchor_box = el.box;
            s.viewport_box = root_box;
        }
        if (ui.state.get(.tooltip, el.id)) |s| {
            s.anchor_box = el.box;
            s.viewport_box = root_box;
        }
    }
}

fn currentMouseHit(ui: *UI) Element.Id {
    return mouseHit(ui, ui.input.mouse_pos);
}

fn mouseHit(ui: *UI, pos: [2]f64) Element.Id {
    return hitTarget(ui, .{ @floatCast(pos[0]), @floatCast(pos[1]) });
}

fn captureHitAncestors(allocator: Allocator, layout_ctx: *layout.Context, id: Element.Id, out: *std.ArrayList(Element.Id)) !void {
    out.clearRetainingCapacity();
    var slot = layout_ctx.slotForId(id) orelse return;
    while (slot != Element.INVALID_SLOT) {
        const el = layout_ctx.pool.get(slot);
        try out.append(allocator, el.id);
        slot = el.parent;
    }
}

fn resolveWindow(ui: *UI, input: input_types.Input, now_ms: i64, content_scale: f32) !void {
    ui.content_scale = content_scale;
    ui.state.selection_text = &.{};
    ui.input.collect(input, now_ms);

    if (ui.input.focus_lost or ui.input.pointer_cancelled) {
        ui.state.active = Element.INVALID_ID;
        ui.state.press_origin = Element.INVALID_ID;
        ui.press_ancestors.clearRetainingCapacity();
        ui.state.press_drag = false;
    }

    if (ui.layout_ctx.has_scroll) try scrollbar.route(ui);

    if (ui.input_scopes.hasActive()) {
        if (!ui.acceptsInput(ui.state.hovered)) ui.state.hovered = Element.INVALID_ID;
        if (!ui.acceptsInput(ui.state.focused)) ui.state.focused = Element.INVALID_ID;
        if (!ui.acceptsInput(ui.state.active)) ui.state.active = Element.INVALID_ID;
        if (!ui.acceptsInput(ui.state.press_origin)) {
            ui.state.press_origin = Element.INVALID_ID;
            ui.press_ancestors.clearRetainingCapacity();
        }
    }

    if (ui.input.containsKey(.tab)) {
        advanceFocus(ui, ui.input.shift_held);
        ui.input.consumeKeyboard();
    }

    ui.state.hovered = currentMouseHit(ui);
    try captureHitAncestors(ui.allocator, &ui.layout_ctx, ui.state.hovered, &ui.hover_ancestors);

    if (ui.input.mouseButton(.left).pressed) {
        const press_pos = ui.input.mouseButton(.left).pressed_pos orelse ui.input.mouse_pos;
        const press_hit = mouseHit(ui, press_pos);
        try captureHitAncestors(ui.allocator, &ui.layout_ctx, press_hit, &ui.press_ancestors);
        ui.state.active = press_hit;
        ui.state.focused = press_hit;
        ui.state.press_origin = press_hit;
        ui.state.press_pos = press_pos;
        ui.state.press_drag = false;

        ui.state.forEach(.text_select, press_hit, clearOtherTextSelect);
    }
    if (ui.input.mouseButton(.left).down and !ui.state.press_drag) {
        const dx = ui.input.mouse_pos[0] - ui.state.press_pos[0];
        const dy = ui.input.mouse_pos[1] - ui.state.press_pos[1];
        if (dx * dx + dy * dy > press_drag_threshold_sq) ui.state.press_drag = true;
    }
    if (ui.input.mouseButton(.left).released and !ui.input.mouseButton(.left).down) ui.state.active = Element.INVALID_ID;
}

fn syncAccessibility(ui: *UI) !void {
    if (ui.accessibility_nodes.items.len == 0) {
        try ui.accessibility_nodes.ensureUnusedCapacity(ui.allocator, 1);
        try ui.accessibility_node_indices.ensureUnusedCapacity(ui.allocator, 1);
        ui.accessibility_nodes.appendAssumeCapacity(Accessibility.root_node);
        ui.accessibility_node_indices.putAssumeCapacity(Accessibility.root_id, 0);
    }
    const count: u32 = @intCast(ui.accessibility_nodes.items.len);
    if (count > Accessibility.nodes_max) return error.TooManyAccessibilityNodes;
    ui.accessibility_nodes.items[0].bounds = if (ui.layout_ctx.root_slot == Element.INVALID_SLOT)
        .zero
    else
        ui.layout_ctx.pool.get(ui.layout_ctx.root_slot).box;
    std.debug.assert(ui.accessibility_nodes.items[0].id == Accessibility.root_id);
    std.debug.assert(ui.accessibility_node_indices.get(Accessibility.root_id) != null);
    for (ui.accessibility_nodes.items[1..]) |*node| {
        const slot = ui.layout_ctx.slotForId(node.id);
        if (slot) |element_slot| {
            const element = ui.layout_ctx.pool.get(element_slot);
            node.bounds = element.box;
            node.state.focused = node.id == ui.state.focused;
        }
        if (node.parent == Element.INVALID_ID) {
            node.parent = Accessibility.root_id;
            if (slot) |element_slot| {
                var parent_slot = ui.layout_ctx.pool.get(element_slot).parent;
                var traversed: u32 = 0;
                const slot_count: u32 = @intCast(ui.layout_ctx.pool.elements.items.len);
                while (parent_slot != Element.INVALID_SLOT and traversed < slot_count) : (traversed += 1) {
                    const parent = ui.layout_ctx.pool.get(parent_slot);
                    if (ui.accessibility_node_indices.contains(parent.id)) {
                        node.parent = parent.id;
                        break;
                    }
                    parent_slot = parent.parent;
                }
                std.debug.assert(traversed <= slot_count);
            }
        } else {
            const parent_index = ui.accessibility_node_indices.get(node.parent) orelse return error.InvalidAccessibilityParent;
            if (slot == null) node.bounds = ui.accessibility_nodes.items[parent_index].bounds;
        }
        node.actions = .empty;
        if (node.state.disabled) continue;
        switch (node.role) {
            .button, .checkbox, .radio, .list_box_option => {
                node.actions.insert(.focus);
                node.actions.insert(.click);
            },
            .slider => {
                node.actions.insert(.focus);
                node.actions.insert(.set_value);
                node.actions.insert(.increment);
                node.actions.insert(.decrement);
            },
            .text_input => {
                node.actions.insert(.focus);
                node.actions.insert(.set_value);
                node.actions.insert(.replace_selected_text);
                node.actions.insert(.set_text_selection);
            },
            .select => {
                node.actions.insert(.focus);
                node.actions.insert(.click);
                node.actions.insert(.expand);
                node.actions.insert(.collapse);
            },
            else => {},
        }
    }
    const nodes = ui.accessibility_nodes.items;
    for (nodes[1..]) |node| {
        const parent_index = ui.accessibility_node_indices.get(node.parent) orelse unreachable;
        nodes[parent_index].child_count += 1;
    }
    var offset: u32 = 0;
    for (nodes) |*node| {
        node.child_start = offset;
        offset += node.child_count;
    }
    std.debug.assert(offset == count - 1);
    try ui.accessibility_children.resize(ui.allocator, offset);
    var cursors: [Accessibility.nodes_max]u32 = @splat(0);
    for (nodes[1..]) |node| {
        const parent_index = ui.accessibility_node_indices.get(node.parent) orelse unreachable;
        const child_index = nodes[parent_index].child_start + cursors[parent_index];
        ui.accessibility_children.items[child_index] = node.id;
        cursors[parent_index] += 1;
    }
}

fn advanceFocus(ui: *UI, backward: bool) void {
    const order = ui.focus_order.items;
    if (order.len == 0) {
        ui.state.focused = Element.INVALID_ID;
        ui.state.active = Element.INVALID_ID;
        return;
    }
    const front_floating = if (ui.input_scopes.hasActive()) null else ui.state.frontFloatingWindow();

    var current_index: ?usize = null;
    for (order, 0..) |id, i| {
        if (id == ui.state.focused) {
            current_index = i;
            break;
        }
    }

    const start = if (current_index) |i|
        if (backward) (i + order.len - 1) % order.len else (i + 1) % order.len
    else if (backward)
        order.len - 1
    else
        0;

    var offset: usize = 0;
    while (offset < order.len) : (offset += 1) {
        const idx = if (backward)
            (start + order.len - offset) % order.len
        else
            (start + offset) % order.len;
        const id = order[idx];
        if (!ui.acceptsInput(id)) continue;
        if (front_floating) |root_id| {
            if (!isDescendantOrSelf(ui, id, root_id)) continue;
        }

        ui.state.focused = id;
        ui.state.active = Element.INVALID_ID;
        return;
    }

    ui.state.focused = Element.INVALID_ID;
    ui.state.active = Element.INVALID_ID;
}

/// Advance the per widget state TTL clock. Call once per frame after the
/// users frame callback has had a chance to touch its state, otherwise
/// entries lose a frame of TTL grace before the sweep sees them.
fn endStateFrame(ui: *UI) !void {
    try ui.state.endFrame();
    ui.input_scopes.resolveActive();
}

fn clearOtherTextSelect(hovered: Element.Id, id: Element.Id, s: *State.TextSelect) void {
    if (id == hovered) return;
    s.anchor_byte = 0;
    s.cursor_byte = 0;
    s.dragging = false;
}

fn appendHit(ui: *UI, id: Element.Id, bounds: math.Rect, clip: Clip.State, layer: Layer, input_scope: Element.Id) !void {
    try ui.hit_records.append(ui.allocator, .{
        .id = id,
        .bounds = bounds,
        .clip = clip,
        .layer = layer,
        .input_scope = input_scope,
        .insertion_order = ui.hit_counter,
    });
    ui.hit_counter += 1;
}

fn resolveHit(ui: *UI) bool {
    const best_id = currentMouseHit(ui);
    const changed = ui.state.hovered != best_id;
    ui.state.hovered = best_id;
    updateStats(ui);
    return changed;
}

fn hitLayerAt(ui: *UI, point: math.Vec2) ?Layer {
    var best: ?HitRecord = null;
    for (ui.hit_records.items) |record| {
        if (!record.bounds.contains(point)) continue;
        if (!Clip.contains(record.clip, ui.clip_nodes.items, point)) continue;
        if (!ui.input_scopes.allows(record.input_scope)) continue;
        if (best) |previous| {
            if (previous.layer.above(record.layer)) continue;
            if (previous.layer.eql(record.layer)) {
                if (previous.insertion_order > record.insertion_order) continue;
            }
        }
        best = record;
    }
    return if (best) |record| record.layer else null;
}

fn hitTarget(ui: *UI, p: math.Vec2) Element.Id {
    var best_id: Element.Id = Element.INVALID_ID;
    var best_layer: Layer = Layer.base;
    var best_order: u32 = 0;

    for (ui.hit_records.items) |rec| {
        if (!rec.bounds.contains(p)) continue;
        if (!Clip.contains(rec.clip, ui.clip_nodes.items, p)) continue;
        if (!ui.input_scopes.allows(rec.input_scope)) continue;

        if (best_id == Element.INVALID_ID or
            rec.layer.above(best_layer) or
            (rec.layer.eql(best_layer) and rec.insertion_order > best_order))
        {
            best_id = rec.id;
            best_layer = rec.layer;
            best_order = rec.insertion_order;
        }
    }

    return best_id;
}

fn updateStats(ui: *UI) void {
    ui.last_stats = .{
        .elements = ui.layout_ctx.pool.elements.items.len,
        .hit_records = ui.hit_records.items.len,
        .scroll_containers = ui.layout_ctx.scroll_slots.items.len,
        .decorations = ui.decorations.items.len,
        .layers = ui.layout_ctx.z_used.count(),
    };
}

fn tessellate(ui: *UI, allocator: Allocator, draw_list: *DrawList) !void {
    defer ui.font.endFrame();

    try buildClipStates(ui);
    try draw_list.clip_nodes.appendSlice(draw_list.allocator, ui.clip_nodes.items);

    var it = ui.layout_ctx.z_used.iterator(.{});
    while (it.next()) |z| {
        const layer = Layer.fromIndex(z);
        draw_list.setLayer(layer.index());
        try tessellateLayer(ui, allocator, draw_list, ui.layout_ctx.zSlots(layer.index()), layer);
    }
}

fn buildClipStates(ui: *UI) !void {
    const elements = ui.layout_ctx.pool.elements.items;

    ui.slot_clips.clearRetainingCapacity();
    ui.child_clips.clearRetainingCapacity();
    ui.clip_nodes.clearRetainingCapacity();

    try ui.slot_clips.resize(ui.allocator, elements.len);
    try ui.child_clips.resize(ui.allocator, elements.len);
    try ui.clip_nodes.append(ui.allocator, Clip.Node.empty);

    for (elements, 0..) |*el, idx| {
        const parent_clip = if (el.parent != Element.INVALID_SLOT)
            ui.child_clips.items[el.parent]
        else
            Clip.State{};

        ui.slot_clips.items[idx] = parent_clip;
        ui.child_clips.items[idx] = try childClip(ui, @intCast(idx), parent_clip);
    }
}

fn childClip(ui: *UI, slot: Element.Slot, parent_clip: Clip.State) !Clip.State {
    const el = &ui.layout_ctx.pool.elements.items[slot];
    if (el.overflow == .visible) return parent_clip;

    var clip_rect = el.box;
    var radii: math.Vec4 = @splat(0);
    var has_rounding = false;

    if (ui.clip_shapes.items[slot]) |shape| {
        clip_rect = .init(
            el.box.x() + shape.border_width[3],
            el.box.y() + shape.border_width[0],
            @max(0, el.box.w() - shape.border_width[3] - shape.border_width[1]),
            @max(0, el.box.h() - shape.border_width[0] - shape.border_width[2]),
        );
        radii = .{
            @max(0, shape.corner_radius[0] - @max(shape.border_width[0], shape.border_width[3])),
            @max(0, shape.corner_radius[1] - @max(shape.border_width[0], shape.border_width[1])),
            @max(0, shape.corner_radius[2] - @max(shape.border_width[2], shape.border_width[1])),
            @max(0, shape.corner_radius[3] - @max(shape.border_width[2], shape.border_width[3])),
        };
        has_rounding = !math.isZero(radii);
    }

    var out = parent_clip;
    out.scissor = if (parent_clip.scissor) |scissor| scissor.intersect(clip_rect) else clip_rect;

    if (has_rounding and !clip_rect.isEmpty()) {
        if (Clip.depth(ui.clip_nodes.items, out.node) >= Clip.MAX_DEPTH) return error.ClipStackTooDeep;
        const node_index: u32 = @intCast(ui.clip_nodes.items.len);
        try ui.clip_nodes.append(ui.allocator, .{
            .rect = clip_rect.v,
            .radii = radii,
            .parent = out.node,
            ._pad = .{ 0, 0, 0 },
        });
        out.node = node_index;
    }

    return out;
}

fn tessellateLayer(ui: *UI, allocator: Allocator, draw_list: *DrawList, slots: []const Element.Slot, layer: Layer) !void {
    const content_scale = ui.content_scale;
    const elements = ui.layout_ctx.pool.elements.items;

    for (slots) |slot| {
        const el = &elements[slot];

        const clip = ui.slot_clips.items[slot];
        const clipped_out = if (clip.scissor) |c| !c.overlaps(el.box) else false;
        if (clipped_out) continue;

        if (el.overflow.isScroll()) try scrollbar.recordForTessellate(ui, slot, clip, layer);

        if (el.interactive) try appendHit(ui, el.id, el.box, clip, layer, el.input_scope);

        switch (ui.decorations.items[slot]) {
            .none => {},
            .rect => |r| {
                // The backdrop filters what is already drawn; the fill then tints it.
                if (r.backdrop.isActive() and r.backdrop.isValid()) try draw_list.pushBackdrop(el.box, r.corner_radius.value, r.backdrop, clip);
                const inst = types.Instance{
                    .pos = .{ el.box.x(), el.box.y() },
                    .size = .{ el.box.w(), el.box.h() },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 0, 0 },
                    .color = r.color,
                    .border_color = r.border_color,
                    .corner_radius = r.corner_radius.value,
                    .border_width = r.border_width.value,
                    .prim_type = 0.0,
                };
                try draw_list.pushInstances(&[_]types.Instance{inst}, .atlas, clip);
            },
            .text => |t| if (t.content.len > 0) {
                const face = try ui.font.getFace(t.font);
                const wrap_px: f32 = if (t.wrap) @max(0, el.box.w() * content_scale) else 0;
                const shaped = try face.shapeWrapped(t.content, t.size * content_scale, wrap_px);
                if (shaped.lines.len > 0) {
                    const ascender = shaped.ascender / content_scale;
                    const size_logical = t.size;

                    if (size_logical <= 0) continue;
                    const inv_size = 1.0 / size_logical;

                    var total_glyphs: usize = 0;
                    for (shaped.lines) |ln| total_glyphs += ln.glyphs.len;
                    if (total_glyphs == 0) continue;

                    const batch = (try draw_list.beginTextBatch(total_glyphs, clip)).?;

                    for (shaped.lines) |line| {
                        const baseline = el.box.y() + ascender + line.y / content_scale;
                        for (line.glyphs) |gl| {
                            const rec = gl.record;
                            if (rec.is_empty) continue;

                            const origin_x = el.box.x() + gl.x / content_scale;

                            if (clip.scissor) |c| {
                                const dilation_margin = 2.0 / content_scale;
                                const glyph_bounds = math.Rect.fromMinMax(
                                    .{ origin_x + rec.bounds_em_min[0] * size_logical, baseline - rec.bounds_em_max[1] * size_logical },
                                    .{ origin_x + rec.bounds_em_max[0] * size_logical, baseline - rec.bounds_em_min[1] * size_logical },
                                ).expand(dilation_margin);
                                if (!c.overlaps(glyph_bounds)) continue;
                            }

                            const tex_z_bits: u32 =
                                @as(u32, rec.glyph_location_x) |
                                (@as(u32, rec.glyph_location_y) << 16);
                            const tex_w_bits: u32 =
                                @as(u32, rec.band_x_max) |
                                (@as(u32, rec.band_y_max) << 16);
                            const tex_z: f32 = @bitCast(tex_z_bits);
                            const tex_w: f32 = @bitCast(tex_w_bits);

                            const bnd = [4]f32{
                                rec.band_scale[0],  rec.band_scale[1],
                                rec.band_offset[0], rec.band_offset[1],
                            };

                            try draw_list.pushTextInstance(batch, .{
                                .bounds = .{ rec.bounds_em_min[0], rec.bounds_em_max[1], rec.bounds_em_max[0], rec.bounds_em_min[1] },
                                .origin_size = .{ origin_x, baseline, size_logical, inv_size },
                                .glyph = .{ tex_z, tex_w },
                                .bnd = bnd,
                                .col = t.color,
                            });
                        }
                    }
                }
            },
            .canvas => |c| try canvas_tessellator.tessellate(allocator, draw_list, c.cmds, .{ el.box.x(), el.box.y() }, clip),
            .gpu_canvas => |canvas| {
                try draw_list.pushCustomDraw(&canvas, el.box, clip);
            },
            .image => |img| {
                const zero4 = [4]f32{ 0, 0, 0, 0 };
                const inst = types.Instance{
                    .pos = .{ el.box.x(), el.box.y() },
                    .size = .{ el.box.w(), el.box.h() },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 1, 1 },
                    .color = img.tint,
                    .border_color = zero4,
                    .corner_radius = Radius.zero.value,
                    .border_width = BorderWidth.zero.value,
                    .prim_type = if (img.@"opaque") 4.0 else 2.0,
                };
                try draw_list.pushInstances(&[_]types.Instance{inst}, img.source, clip);
            },
            .range => |r| try renderRange(draw_list, el.box, r, clip),
        }
    }

    try scrollbar.render(ui, draw_list, layer);
    // Scrollbar thumbs are hit targets above their container's content.
    for (ui.scroll_geoms.items) |sg| {
        if (!sg.layer.eql(layer)) continue;
        const el = &elements[sg.slot];
        for (sg.geom.bars) |maybe_bar| {
            const bar = maybe_bar orelse continue;
            try appendHit(ui, scrollbar.idFor(el.id), bar.thumb, sg.parent_clip, layer, el.input_scope);
        }
    }
}

fn renderRange(draw_list: *DrawList, box: math.Rect, r: Decoration.Range, clip: Clip.State) !void {
    const bx = box.x();
    const by = box.y();
    const bw = box.w();
    const bh = box.h();
    const th = @max(0, @min(r.track_height orelse bh, bh));
    const ty = by + (bh - th) * 0.5;
    const progress = std.math.clamp(r.progress, 0.0, 1.0);

    const track = solidRectInstance(bx, ty, bw, th, r.track_color, r.corner_radius);
    try draw_list.pushInstances(&[_]types.Instance{track}, .atlas, clip);

    if (progress > 0) {
        const fill = solidRectInstance(bx, ty, bw * progress, th, r.fill_color, r.corner_radius);
        try draw_list.pushInstances(&[_]types.Instance{fill}, .atlas, clip);
    }

    if (r.halo_radius > 0 and r.halo_color[3] > 0) {
        const hr = r.halo_radius;
        const cx = bx + bw * progress;
        const cy = by + bh * 0.5;
        const halo = solidRectInstance(cx - hr, cy - hr, hr * 2, hr * 2, r.halo_color, Radius.all(hr));
        try draw_list.pushInstances(&[_]types.Instance{halo}, .atlas, clip);
    }

    if (r.knob_radius > 0) {
        const kr = r.knob_radius;
        const cx = bx + bw * progress;
        const cy = by + bh * 0.5;
        const knob = solidRectInstance(cx - kr, cy - kr, kr * 2, kr * 2, r.knob_color, Radius.all(kr));
        try draw_list.pushInstances(&[_]types.Instance{knob}, .atlas, clip);
    }
}

inline fn solidRectInstance(x: f32, y: f32, w: f32, h: f32, color: [4]f32, corner_radius: Radius) types.Instance {
    return .{
        .pos = .{ x, y },
        .size = .{ w, h },
        .uv0 = .{ 0, 0 },
        .uv1 = .{ 0, 0 },
        .color = color,
        .border_color = .{ 0, 0, 0, 0 },
        .corner_radius = corner_radius.value,
        .border_width = BorderWidth.zero.value,
        .prim_type = 0.0,
    };
}

fn isDescendantOrSelf(ui: *UI, descendant_id: Element.Id, ancestor_id: Element.Id) bool {
    if (descendant_id == Element.INVALID_ID) return false;
    if (descendant_id == ancestor_id) return true;
    const ancestor_slot = ui.layout_ctx.slotForId(ancestor_id) orelse return false;
    const descendant_slot = ui.layout_ctx.slotForId(descendant_id) orelse return false;
    return ui.layout_ctx.isDescendantOf(descendant_slot, ancestor_slot);
}

test "scroll routing uses previous frame elements" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    {
        _ = try ui.open(Key.str("root"), .{
            .width = .fixed(300),
            .height = .fixed(200),
            .direction = .column,
            .overflow = .scroll_y,
        }, .none);
        {
            _ = try ui.open(Key.str("child"), .{
                .width = .grow(),
                .height = .fixed(500),
            }, .none);
            ui.close();
        }
        ui.close();

        try resolve(&ui);
    }

    try resolveWindow(&ui, .{
        .pos = .{ 150, 100 },
        .scroll = .{ .pixel = .{ 0, 50 } },
        .chars = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0, 0);
    reset(&ui);

    {
        _ = try ui.open(Key.str("root"), .{
            .width = .fixed(300),
            .height = .fixed(200),
            .direction = .column,
            .overflow = .scroll_y,
        }, .none);
        {
            _ = try ui.open(Key.str("child"), .{
                .width = .grow(),
                .height = .fixed(500),
            }, .none);
            ui.close();
        }
        ui.close();

        try resolve(&ui);
    }

    const child_id = Key.str("child").hash();
    var child_box: ?math.Rect = null;
    for (ui.layout_ctx.pool.elements.items) |el| {
        if (el.id == child_id) {
            child_box = el.box;
            break;
        }
    }

    const box = child_box.?;
    try std.testing.expectApproxEqAbs(box.y(), -50.0, 0.001);
}

fn buildTwoAxisScrollTree(u: *UI) !void {
    _ = try u.open(.str("root"), .{
        .width = .fixed(300),
        .height = .fixed(200),
        .direction = .column,
        .overflow = .scroll,
    }, .none);
    {
        _ = try u.open(.str("child"), .{
            .width = .fixed(600),
            .height = .fixed(800),
        }, .none);
        u.close();
    }
    u.close();
}

fn buildScrollYTree(u: *UI) !void {
    _ = try u.open(.str("root"), .{
        .width = .fixed(300),
        .height = .fixed(200),
        .direction = .column,
        .overflow = .scroll_y,
    }, .none);
    {
        _ = try u.open(.str("child"), .{
            .width = .grow(),
            .height = .fixed(1000),
        }, .none);
        u.close();
    }
    u.close();
}

fn wheelInput(delta: math.Vec2) input_types.Input {
    return .{
        .pos = .{ 50, 50 },
        .scroll = .{ .pixel = delta },
        .chars = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    };
}

fn scrollInput(scroll: input_types.ScrollInput) input_types.Input {
    return .{
        .pos = .{ 50, 50 },
        .scroll = scroll,
        .chars = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    };
}

const testing = std.testing;

test "accessibility root stays first across frames" {
    var ui = try UI.init(std.testing.allocator, .{});
    defer ui.deinit();

    try resolve(&ui);
    try std.testing.expectEqual(@as(usize, 1), ui.accessibility_nodes.items.len);
    try std.testing.expect(ui.accessibility_node_indices.contains(Accessibility.root_id));

    reset(&ui);
    try ui.setAccessibility(42, .{ .role = .button, .name = "First" });
    try ui.setAccessibility(42, .{ .role = .button, .name = "Updated" });
    try resolve(&ui);

    try std.testing.expectEqual(@as(usize, 2), ui.accessibility_nodes.items.len);
    try std.testing.expectEqual(Accessibility.root_id, ui.accessibility_nodes.items[0].id);
    try std.testing.expectEqual(@as(Element.Id, 42), ui.accessibility_nodes.items[1].id);
    try std.testing.expectEqualStrings("Updated", ui.accessibility_nodes.items[1].name);

    reset(&ui);
    try ui.setAccessibility(43, .{ .role = .button, .name = "Next frame" });
    try resolve(&ui);

    try std.testing.expectEqual(@as(usize, 2), ui.accessibility_nodes.items.len);
    try std.testing.expectEqual(Accessibility.root_id, ui.accessibility_nodes.items[0].id);
    try std.testing.expectEqual(@as(Element.Id, 43), ui.accessibility_nodes.items[1].id);
}

test "resolveHit reports hover changes" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    try appendHit(&ui, 42, .init(0, 0, 100, 100), .{}, Layer.base, Element.INVALID_ID);

    ui.input.mouse_pos = .{ 10, 10 };
    try std.testing.expect(resolveHit(&ui));
    try std.testing.expectEqual(@as(Element.Id, 42), ui.state.hovered);

    try std.testing.expect(!resolveHit(&ui));

    ui.input.mouse_pos = .{ 200, 200 };
    try std.testing.expect(resolveHit(&ui));
    try std.testing.expectEqual(Element.INVALID_ID, ui.state.hovered);
}

test "two axis wheel scroll locks one axis per gesture" {
    const allocator = testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    try buildTwoAxisScrollTree(&ui);
    try resolve(&ui);

    try resolveWindow(&ui, wheelInput(.{ 40, 5 }), 0, 0);
    try resolveWindow(&ui, wheelInput(.{ 2, 50 }), scrollbar.WHEEL_LOCK_IDLE_MS - 1, 0);

    const s = ui.state.get(.scroll, Key.str("root").hash()).?;
    try testing.expectEqual(State.Scroll.Axis.x, s.wheel_axis);
    try testing.expectApproxEqAbs(42, s.offset[0], 0.001);
    try testing.expectApproxEqAbs(0, s.offset[1], 0.001);
    try resolveWindow(&ui, wheelInput(.{ 2, 50 }), scrollbar.WHEEL_LOCK_IDLE_MS * 2, 0);

    try testing.expectEqual(State.Scroll.Axis.y, s.wheel_axis);
    try testing.expectApproxEqAbs(42, s.offset[0], 0.001);
    try testing.expectApproxEqAbs(50, s.offset[1], 0.001);
}

test "pixel wheel scroll is independent of content scale" {
    const allocator = testing.allocator;

    var ui1 = try UI.init(allocator, .{});
    defer ui1.deinit();
    try buildScrollYTree(&ui1);
    try resolve(&ui1);
    try resolveWindow(&ui1, wheelInput(.{ 0, 25 }), 0, 1);

    var ui2 = try UI.init(allocator, .{});
    defer ui2.deinit();
    try buildScrollYTree(&ui2);
    try resolve(&ui2);
    try resolveWindow(&ui2, wheelInput(.{ 0, 25 }), 0, 2);

    const root_id = Key.str("root").hash();
    try testing.expectApproxEqAbs(ui1.state.get(.scroll, root_id).?.offset[1], ui2.state.get(.scroll, root_id).?.offset[1], 0.001);
    try testing.expectApproxEqAbs(25, ui1.state.get(.scroll, root_id).?.offset[1], 0.001);
}

test "scrollbar drag moves scroll offset proportionally" {
    const allocator = testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    const root_key = Key.str("root");

    const buildTree = struct {
        fn run(u: *UI) !void {
            _ = try u.open(.str("root"), .{
                .width = .fixed(300),
                .height = .fixed(200),
                .direction = .column,
                .overflow = .scroll_y,
            }, .none);
            {
                _ = try u.open(.str("child"), .{
                    .width = .grow(),
                    .height = .fixed(1000),
                }, .none);
                u.close();
            }
            u.close();
        }
    }.run;

    try buildTree(&ui);
    try resolve(&ui);

    const root_id = root_key.hash();
    var root_el: ?*const Element = null;
    for (ui.layout_ctx.pool.elements.items) |*el| {
        if (el.id == root_id) {
            root_el = el;
            break;
        }
    }

    const geom = scrollbar.compute(root_el.?, .{ 0, 0 }, &ui.theme).?;
    const bar = geom.bars[1].?;
    const thumb_top_y = bar.thumb.y();

    try resolveWindow(&ui, .{
        .pos = .{ bar.thumb.x() + 1, thumb_top_y + 4 },
        .mouse = blk: {
            var buttons: [input_types.mouse_button_count]input_types.MouseButtonState = @splat(.{});
            buttons[@backingInt(input_types.MouseButton.left)].down = true;
            break :blk buttons;
        },
        .scroll = .{},
        .chars = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0, 0);
    reset(&ui);
    try buildTree(&ui);
    try resolve(&ui);

    const s_after_press = ui.state.get(.scroll, root_id).?;
    try testing.expectEqual(State.Scroll.Axis.y, s_after_press.drag_axis);
    try testing.expectApproxEqAbs(4, s_after_press.drag_grab, 0.001);

    const drag_target_y = thumb_top_y + 30;
    try resolveWindow(&ui, .{
        .pos = .{ bar.thumb.x() + 1, drag_target_y },
        .mouse = blk: {
            var buttons: [input_types.mouse_button_count]input_types.MouseButtonState = @splat(.{});
            buttons[@backingInt(input_types.MouseButton.left)].down = true;
            break :blk buttons;
        },
        .scroll = .{},
        .chars = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0, 0);

    const free = bar.track.h() - bar.thumb.h();
    const max_off: f32 = 1000 - 200;
    const expected_t = (drag_target_y - 4 - bar.track.y()) / free;
    const expected_offset = expected_t * max_off;

    const s_after_drag = ui.state.get(.scroll, root_id).?;
    try testing.expectApproxEqAbs(expected_offset, s_after_drag.offset[1], 0.5);

    try resolveWindow(&ui, .{
        .pos = .{ bar.thumb.x() + 1, drag_target_y },
        .scroll = .{},
        .chars = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0, 0);

    const s_after_release = ui.state.get(.scroll, root_id).?;
    try testing.expectEqual(State.Scroll.Axis.none, s_after_release.drag_axis);
}

test "wheel scroll over container updates offset" {
    const allocator = testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    const root_key = Key.str("root");

    const buildTree = struct {
        fn run(u: *UI) !void {
            _ = try u.open(.str("root"), .{
                .width = .fixed(300),
                .height = .fixed(200),
                .direction = .column,
                .overflow = .scroll_y,
            }, .none);
            {
                _ = try u.open(.str("child"), .{
                    .width = .grow(),
                    .height = .fixed(1000),
                }, .none);
                u.close();
            }
            u.close();
        }
    }.run;

    try buildTree(&ui);
    try resolve(&ui);

    try resolveWindow(&ui, .{
        .pos = .{ 50, 50 },
        .scroll = .{ .pixel = .{ 0, 25 } },
        .chars = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0, 0);

    const root_id = root_key.hash();
    const s = ui.state.get(.scroll, root_id).?;
    try testing.expectApproxEqAbs(25, s.offset[1], 0.001);
}

const CullingTest = struct {
    const rows = 100;
    const row_height = 40;

    fn build(u: *UI) !void {
        _ = try u.open(.str("list"), .{ .width = .fixed(300), .height = .fixed(200), .direction = .column, .overflow = .scroll_y }, .none);
        for (0..rows) |i| {
            _ = try u.open(Key.str("row").indexed(i), .{ .width = .grow(), .direction = .column }, .none);
            if (!u.culling()) {
                _ = try u.open(Key.str("cell").indexed(i), .{ .width = .grow(), .height = .fixed(row_height) }, .none);
                u.close();
            }
            u.close();
        }
        u.close();
    }

    fn frame(u: *UI) !void {
        reset(u);
        try build(u);
        try resolve(u);
    }

    fn rowBox(u: *UI, i: usize) math.Rect {
        const slot = u.layout_ctx.slotForId(Key.str("row").indexed(i).hash()).?;
        return u.layout_ctx.pool.get(slot).box;
    }
};

test "rows far outside a scroll container are culled and keep their size" {
    var ui = try UI.init(testing.allocator, .{});
    defer ui.deinit();
    ui.accessibility_enabled = false;

    try CullingTest.frame(&ui);
    try testing.expectEqual(0, ui.culled_count);
    const full_elements = ui.layout_ctx.pool.elements.items.len;
    const last_row = CullingTest.rowBox(&ui, CullingTest.rows - 1);

    try CullingTest.frame(&ui);
    try testing.expectEqual(CullingTest.rows - 10, ui.culled_count);
    try testing.expectEqual(full_elements - ui.culled_count, ui.layout_ctx.pool.elements.items.len);
    try testing.expectEqual(last_row, CullingTest.rowBox(&ui, CullingTest.rows - 1));
}

test "scrolling rebuilds culled rows near the new offset" {
    var ui = try UI.init(testing.allocator, .{});
    defer ui.deinit();
    ui.accessibility_enabled = false;

    try CullingTest.frame(&ui);
    try CullingTest.frame(&ui);
    (try ui.state.getOrCreate(.scroll, ui.allocator, Key.str("list").hash())).offset = .{ 0, 3000 };
    try CullingTest.frame(&ui);

    const visible = CullingTest.rowBox(&ui, 75);
    try testing.expectEqual(@as(f32, CullingTest.row_height), visible.h());
    try testing.expect(ui.layout_ctx.slotForId(Key.str("cell").indexed(75).hash()) != null);
    try testing.expect(ui.layout_ctx.slotForId(Key.str("cell").indexed(0).hash()) == null);
}

test "no culling while accessibility is enabled" {
    var ui = try UI.init(testing.allocator, .{});
    defer ui.deinit();

    try CullingTest.frame(&ui);
    try CullingTest.frame(&ui);
    try testing.expectEqual(0, ui.culled_count);
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
                .style = &.{ .width = .fixed(120), .height = .fixed(80), .background = .primary },
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
    const root: @import("component/Rect.zig") = .{ .key = .str("parent"), .style = &.{ .width = .fixed(120), .height = .fixed(80) } };
    _ = try root.open(&frame);
    try frame.contribute(.str("region"), 1, &callback, Callback.draw);
    try std.testing.expectError(error.RepeatedModule, frame.contribute(.str("duplicate"), 1, &callback, Callback.draw));
    try root.close(&frame);
    _ = try frame.ui().openWith(.str("host.overlay"), .{
        .width = .fixed(120),
        .height = .fixed(80),
        .interactive = true,
        .z_index = Frame.host_overlay_layer_min,
    }, .{ .rect = .{ .color = .{ 0, 0, 0, 1 } } }, .{ .root = .{ 0, 0 } });
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
