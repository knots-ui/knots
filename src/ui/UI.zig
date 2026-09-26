const input_types = @import("input");
const layout = @import("layout");
const text = @import("text");
const math = @import("math");

const Element = layout.Element;
const std = @import("std");
const render = @import("render");
const Clip = render.Clip;

const State = @import("State.zig");
const Input = @import("Input.zig");
const InputScope = @import("InputScope.zig");
const Accessibility = @import("Accessibility.zig");
const animation = @import("animation.zig");

const Decoration = @import("decoration.zig").Decoration;
const Key = @import("Key.zig");
const style = @import("style");
const Theme = style.Theme;
const FontSize = style.FontSize;
const Layer = layout.Layer;
const scrollbar = @import("scrollbar.zig");

const Allocator = std.mem.Allocator;

pub const INVALID_ID = Element.INVALID_ID;
pub const InputScopeConfig = InputScope.Config;

pub const HitRecord = struct {
    id: Element.Id,
    bounds: math.Rect,
    clip: Clip.State,
    layer: Layer,
    input_scope: Element.Id,
    insertion_order: u32,
};

pub const HitTarget = enum {
    exact,
    within,
    root,
};

pub const Config = struct {
    /// Default is Roboto regular + Material icons regular.
    fonts: []const text.Font.FontSource = &.{.{
        .name = "default",
        .data = @embedFile("fonts/default.ttf"),
    }},
    /// Per-pool eviction TTLs in frames. Long-lived widget state (cursor,
    /// scroll, dropdown-open, selection) survives conditional hiding (Tabs,
    /// Accordion, Tree); short-lived state (anim) is evicted promptly.
    state_ttls: State.Ttls = .{},
    scroll_line_size: FontSize.Input = .sm,
    theme: Theme = Theme.light,
};

pub const Stats = struct {
    elements: usize = 0,
    hit_records: usize = 0,
    scroll_containers: usize = 0,
    decorations: usize = 0,
    layers: usize = 0,
};

allocator: Allocator,
layout_ctx: layout.Context,
decorations: std.ArrayList(Decoration),
/// Inherited style content per slot, parallel to `decorations`.
contents: std.ArrayList(style.Content),
font: text.Font,
state: State,
input: Input,
hit_records: std.ArrayList(HitRecord),
press_ancestors: std.ArrayList(Element.Id),
hover_ancestors: std.ArrayList(Element.Id),
focus_order: std.ArrayList(Element.Id),
accessibility_nodes: std.ArrayList(Accessibility.Node),
accessibility_children: std.ArrayList(Element.Id) = .empty,
accessibility_node_indices: std.AutoHashMapUnmanaged(Element.Id, u32) = .empty,
accessibility_actions: []const Accessibility.ActionRequest = &.{},
accessibility_consumed: [Accessibility.actions_max]bool = @splat(false),
hit_counter: u32,
scroll_geoms: std.ArrayList(scrollbar.SlotGeom),
clip_shapes: std.ArrayList(?Clip.Shape),
slot_clips: std.ArrayList(Clip.State),
child_clips: std.ArrayList(Clip.State),
clip_nodes: std.ArrayList(Clip.Node),
input_scopes: InputScope,
content_scale: f32,
scroll_line_size: FontSize.Input,
anim_active: bool,
text_input_requested: bool,
theme: Theme,
last_stats: Stats,
cursor_shape: input_types.CursorShape,

const UI = @This();

pub fn init(allocator: Allocator, cfg: Config) !UI {
    return .{
        .allocator = allocator,
        .layout_ctx = .init(allocator),
        .decorations = .empty,
        .contents = .empty,
        .state = .init(allocator, cfg.state_ttls),
        .input = .{},
        .font = try .init(allocator, cfg.fonts),
        .hit_records = .empty,
        .press_ancestors = .empty,
        .hover_ancestors = .empty,
        .focus_order = .empty,
        .accessibility_nodes = .empty,
        .hit_counter = 0,
        .scroll_geoms = .empty,
        .clip_shapes = .empty,
        .slot_clips = .empty,
        .child_clips = .empty,
        .clip_nodes = .empty,
        .input_scopes = .{},
        .content_scale = 1.0,
        .scroll_line_size = cfg.scroll_line_size,
        .anim_active = false,
        .text_input_requested = false,
        .theme = cfg.theme,
        .last_stats = .{},
        .cursor_shape = .default,
    };
}

pub fn deinit(self: *UI) void {
    self.layout_ctx.deinit();
    self.decorations.deinit(self.allocator);
    self.contents.deinit(self.allocator);
    self.font.deinit();
    self.state.deinit();
    self.hit_records.deinit(self.allocator);
    self.press_ancestors.deinit(self.allocator);
    self.hover_ancestors.deinit(self.allocator);
    self.focus_order.deinit(self.allocator);
    Accessibility.freeNodes(self.allocator, self.accessibility_nodes.items);
    self.accessibility_nodes.deinit(self.allocator);
    self.accessibility_children.deinit(self.allocator);
    self.accessibility_node_indices.deinit(self.allocator);
    self.scroll_geoms.deinit(self.allocator);
    self.clip_shapes.deinit(self.allocator);
    self.slot_clips.deinit(self.allocator);
    self.child_clips.deinit(self.allocator);
    self.clip_nodes.deinit(self.allocator);
    self.input_scopes.deinit(self.allocator);
}

pub fn open(self: *UI, key: Key, element: Element.Config, decoration: Decoration) !Element.Id {
    return self.openWith(key, element, decoration, .{});
}

pub const OpenOptions = struct {
    /// Inherited style scope for descendants; defaults to the parent's.
    content: ?style.Content = null,
    /// Open a new layout root at this viewport position (popups, overlays)
    /// instead of a child of the current element.
    root: ?[2]f32 = null,
};

pub fn openWith(self: *UI, key: Key, element: Element.Config, decoration: Decoration, options: OpenOptions) !Element.Id {
    var cfg = element;
    if (options.root != null and self.layout_ctx.stack.items.len > 0) {
        cfg.z_index = State.overlayWithin(self.currentLayer(), Layer.fromIndex(cfg.z_index)).index();
    }

    const id = key.hash();
    try self.decorations.ensureUnusedCapacity(self.allocator, 1);
    try self.contents.ensureUnusedCapacity(self.allocator, 1);
    try self.clip_shapes.ensureUnusedCapacity(self.allocator, 1);
    if (cfg.focusable) try self.focus_order.ensureUnusedCapacity(self.allocator, 1);
    const content = options.content orelse self.parentContent();
    const slot = if (options.root != null) try self.layout_ctx.openRoot(id, cfg) else try self.layout_ctx.open(id, cfg);
    const slot_index: usize = @intCast(slot);
    std.debug.assert(self.decorations.items.len == slot_index);
    std.debug.assert(self.contents.items.len == slot_index);
    std.debug.assert(self.clip_shapes.items.len == slot_index);
    self.decorations.appendAssumeCapacity(decoration);
    self.contents.appendAssumeCapacity(content);
    self.clip_shapes.appendAssumeCapacity(clipShapeFromDecoration(decoration));
    const el = self.layout_ctx.pool.get(slot);
    el.input_scope = self.input_scopes.current();
    if (options.root) |pos| {
        el.box.setX(pos[0]);
        el.box.setY(pos[1]);
    }
    if (decoration == .text) {
        el.intrinsic_w = decoration.text.intrinsic_w;
        el.intrinsic_h = decoration.text.intrinsic_h;
    }
    if (cfg.focusable) self.focus_order.appendAssumeCapacity(id);
    return id;
}

pub fn close(self: *UI) void {
    self.layout_ctx.close();
}

/// Layer of the element being built.
pub fn currentLayer(self: *UI) Layer {
    const stack = self.layout_ctx.stack.items;
    if (stack.len == 0) return .base;
    return .fromIndex(self.layout_ctx.pool.get(stack[stack.len - 1]).z_index);
}

fn clipShapeFromDecoration(decoration: Decoration) ?Clip.Shape {
    return switch (decoration) {
        .rect => |r| .{
            .corner_radius = r.corner_radius.value,
            .border_width = r.border_width.value,
        },
        else => null,
    };
}

pub fn beginInputScope(self: *UI, id: Element.Id, config: InputScopeConfig) !void {
    const slot = self.layout_ctx.slotForId(id) orelse unreachable;
    const el = self.layout_ctx.pool.get(slot);
    try self.input_scopes.begin(self.allocator, id, config, Layer.fromIndex(el.z_index));
    el.input_scope = id;
}

pub fn endInputScope(self: *UI, id: Element.Id) void {
    self.input_scopes.end(id);
}

pub fn cancelInputScope(self: *UI, id: Element.Id) void {
    self.input_scopes.cancel(id);
}

pub fn isActiveScope(self: *UI, id: Element.Id) bool {
    return self.input_scopes.isActive(id);
}

pub fn acceptsInput(self: *UI, id: Element.Id) bool {
    return self.inputScopeAllowsId(id);
}

/// Line height in logical pixels for a font size in logical pixels.
pub fn lineHeight(self: *UI, size: f32, font: ?[]const u8) !f32 {
    const face = try self.font.getFace(font);
    const scale = self.content_scale;
    return (try face.lineHeight(size * scale)) / scale;
}

pub fn textDecoration(self: *UI, content: []const u8, size: f32, font: ?[]const u8, wrap: bool) !Decoration {
    const face = try self.font.getFace(font);
    const scale = self.content_scale;
    if (wrap) {
        const lh = (try face.lineHeight(size * scale)) / scale;
        return .{ .text = .{
            .content = content,
            .size = size,
            .font = font,
            .intrinsic_w = 0,
            .intrinsic_h = lh,
            .wrap = true,
        } };
    }
    const measured = try face.measure(content, size * scale);
    return .{ .text = .{
        .content = content,
        .size = size,
        .font = font,
        .intrinsic_w = measured.width / scale,
        .intrinsic_h = measured.height / scale,
        .wrap = false,
    } };
}

/// The inherited style scope of the element being built (the stack top), or the root scope.
pub fn parentContent(self: *const UI) style.Content {
    const stack = self.layout_ctx.stack.items;
    if (stack.len == 0) return style.rootContent(&self.theme);
    return self.contents.items[stack[stack.len - 1]];
}

/// hover / focus / active from last frame's hit records; the component supplies the rest.
pub fn states(self: *UI, id: Element.Id, extra: style.States) style.States {
    var st = extra;
    if (st.disabled) return st;
    st.hover = st.hover or self.hovering(id);
    st.focus = st.focus or self.focused(id);
    st.active = st.active or self.pressing(id);
    return st;
}

/// Resolve against `parent` (default: the current element's Content), then apply the
/// transition if any. Opens no element: use it for parts drawn inside one decoration
/// (slider track/fill/thumb), or pass an explicit parent for popups opened after
/// their anchor closed.
pub fn resolveStyle(self: *UI, id: Element.Id, cascade: style.Cascade, st: style.States, parent: ?*const style.Content) style.Resolved {
    const inherited = if (parent) |p| p.* else self.parentContent();
    var resolved = style.resolve(cascade, st, &inherited, &self.theme);
    if (resolved.transition) |transition| resolved.setVisual(self.transitionVisual(id, resolved.visual(), transition));
    return resolved;
}

pub const Styled = struct { id: Element.Id, resolved: style.Resolved };

/// resolveStyle + open(resolved.element(flags), surface) + record resolved.content
/// as this slot's Content. Paired with `close()`.
pub fn openStyled(self: *UI, key: Key, cascade: style.Cascade, st: style.States, flags: style.Resolved.Flags) !Styled {
    const resolved = self.resolveStyle(key.hash(), cascade, st, null);
    const config = resolved.element(flags);
    const id = try self.openResolved(key, &resolved, config, null);
    return .{ .id = id, .resolved = resolved };
}

/// Open an element for an already resolved style: its surface as the decoration and
/// its content as the inherited scope. `config` is usually `resolved.element(flags)`,
/// adjusted by the component. `root` opens a new layout root at that position.
pub fn openResolved(self: *UI, key: Key, resolved: *const style.Resolved, config: Element.Config, root: ?[2]f32) !Element.Id {
    return self.openWith(key, config, surfaceDecoration(resolved, config), .{ .content = resolved.content, .root = root });
}

/// Surface decoration for a resolved style, or `.none` when nothing would draw or clip.
fn surfaceDecoration(resolved: *const style.Resolved, config: Element.Config) Decoration {
    const surface = resolved.surface;
    const needs_clip_shape = config.overflow != .visible and (!surface.corner_radius.isZero() or !surface.border_width.isZero());
    return if (surface.isVisible() or needs_clip_shape) .{ .rect = surface } else .none;
}

/// Text decoration from resolved content (replaces the (size, font, color) plumbing).
pub fn textDecorationStyled(self: *UI, content: []const u8, resolved: *const style.Resolved) !Decoration {
    var decoration = try self.textDecoration(content, resolved.content.font_size, resolved.content.font, resolved.wrap);
    decoration.text.color = resolved.content.foreground;
    return decoration;
}

/// Open and close a non-interactive text leaf styled by `cascade`.
pub fn styledText(self: *UI, key: Key, content: []const u8, cascade: style.Cascade, st: style.States) !Element.Id {
    const resolved = self.resolveStyle(key.hash(), cascade, st, null);
    const decoration = try self.textDecorationStyled(content, &resolved);
    const id = try self.openWith(key, resolved.element(.{}), decoration, .{ .content = resolved.content });
    self.close();
    return id;
}

fn transitionVisual(self: *UI, id: Element.Id, target: style.Visual, transition: style.Transition) style.Visual {
    const s: *State.StyleTransition = self.state.getOrCreate(.style_transition, self.allocator, id) catch return target;
    const now = self.input.now_ms;
    if (!s.initialized) {
        s.* = .{ .from = target, .to = target, .t0_ms = now, .duration_ms = transition.duration_ms, .ease = transition.ease, .initialized = true };
        return target;
    }
    if (!s.to.eql(target)) {
        s.from = sampleTransition(s, now).visual;
        s.to = target;
        s.t0_ms = now;
        s.duration_ms = transition.duration_ms;
        s.ease = transition.ease;
    }
    const sample = sampleTransition(s, now);
    if (sample.t < 1.0) self.anim_active = true;
    return sample.visual;
}

fn sampleTransition(s: *const State.StyleTransition, now_ms: i64) struct { visual: style.Visual, t: f32 } {
    if (s.duration_ms == 0) return .{ .visual = s.to, .t = 1.0 };
    const elapsed: f32 = @floatFromInt(now_ms - s.t0_ms);
    const t = std.math.clamp(elapsed / @as(f32, @floatFromInt(s.duration_ms)), 0.0, 1.0);
    if (t >= 1.0) return .{ .visual = s.to, .t = 1.0 };
    return .{ .visual = s.from.lerp(s.to, s.ease.eval(t)), .t = t };
}

/// Replaces only the draw decoration.
/// Overflow clip shape is captured when the slot is opened so canvas-like components can replace their drawing later.
pub fn setDecoration(self: *UI, slot: Element.Slot, decoration: Decoration) void {
    self.decorations.items[slot] = decoration;
}

pub fn currentSlot(self: *UI) Element.Slot {
    const stack = self.layout_ctx.stack.items;
    return stack[stack.len - 1];
}

pub fn requestCursor(self: *UI, shape: input_types.CursorShape) void {
    self.cursor_shape = shape;
}

pub fn requestTextInput(self: *UI) void {
    self.text_input_requested = true;
}

/// Drive a time-based animation toward `target` for the given (element_id, channel)
/// pair. Returns the current eased value. On target change, snapshots the current
/// value as the new start_value so interrupted animations continue smoothly from
/// wherever they were rather than restarting.
///
/// Marks the UI dirty while in flight so the host app can keep ticking frames.
pub fn anim(self: *UI, element_id: Element.Id, channel: []const u8, target: f32, opts: animation.Options) f32 {
    const id = animation.channelId(element_id, channel);
    const s: *State.Anim = self.state.getOrCreate(.anim, self.allocator, id) catch return target;
    const now = self.input.now_ms;

    if (!s.initialized) {
        s.* = .{
            .current = target,
            .start_value = target,
            .target = target,
            .t0_ms = now,
            .duration_ms = opts.duration_ms,
            .ease = opts.ease,
            .initialized = true,
        };
        return target;
    }

    if (s.target != target) {
        s.current = sampleAnim(s, now).value;
        s.start_value = s.current;
        s.target = target;
        s.t0_ms = now;
        s.duration_ms = opts.duration_ms;
        s.ease = opts.ease;
    }

    if (s.duration_ms == 0) {
        s.current = target;
        return s.current;
    }

    const sample = sampleAnim(s, now);
    s.current = sample.value;
    if (sample.t < 1.0) self.anim_active = true;
    return s.current;
}

const AnimSample = struct {
    value: f32,
    t: f32,
};

fn sampleAnim(s: *const State.Anim, now_ms: i64) AnimSample {
    if (s.duration_ms == 0) return .{ .value = s.target, .t = 1.0 };
    const elapsed: i64 = now_ms - s.t0_ms;
    const raw_t: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(s.duration_ms));
    const t = std.math.clamp(raw_t, 0.0, 1.0);
    return .{
        .value = math.lerp(s.start_value, s.target, s.ease.eval(t)),
        .t = t,
    };
}

pub fn setAccessibility(self: *UI, id: Element.Id, meta: Accessibility.Metadata) !void {
    if (id == Element.INVALID_ID) return;
    if (id == Accessibility.root_id) return error.ReservedAccessibilityId;
    const existing_index = self.accessibility_node_indices.get(id);
    if (existing_index == null and self.accessibility_nodes.items.len >= Accessibility.nodes_max) return error.TooManyAccessibilityNodes;

    const name = try self.dupeAccessibilityText(meta.name);
    errdefer self.freeAccessibilityText(name);
    var state = meta.state;
    if (meta.state.value_text) |value| {
        state.value_text = try self.dupeAccessibilityText(value);
    }
    errdefer if (state.value_text) |value| self.freeAccessibilityText(value);

    if (existing_index) |index| {
        std.debug.assert(index < self.accessibility_nodes.items.len);
        const node = &self.accessibility_nodes.items[index];
        std.debug.assert(node.id == id);
        self.freeAccessibilityNode(node);
        node.role = meta.role;
        node.parent = meta.parent orelse Element.INVALID_ID;
        node.text_run_id = meta.text_run_id;
        node.name = name;
        node.state = state;
        return;
    }

    const root_missing = self.accessibility_nodes.items.len == 0;
    try self.accessibility_nodes.ensureUnusedCapacity(self.allocator, if (root_missing) 2 else 1);
    try self.accessibility_node_indices.ensureUnusedCapacity(self.allocator, if (root_missing) 2 else 1);
    if (root_missing) {
        self.accessibility_nodes.appendAssumeCapacity(Accessibility.root_node);
        self.accessibility_node_indices.putAssumeCapacity(Accessibility.root_id, 0);
    }
    const index: u32 = @intCast(self.accessibility_nodes.items.len);
    self.accessibility_nodes.appendAssumeCapacity(.{
        .id = id,
        .parent = meta.parent orelse Element.INVALID_ID,
        .text_run_id = meta.text_run_id,
        .role = meta.role,
        .name = name,
        .state = state,
    });
    self.accessibility_node_indices.putAssumeCapacity(id, index);
}

pub fn consumeAccessibilityAction(self: *UI, id: Element.Id, action: Accessibility.Action) ?Accessibility.ActionRequest {
    std.debug.assert(self.accessibility_actions.len <= Accessibility.actions_max);
    for (self.accessibility_actions, 0..) |request, index| {
        if (self.accessibility_consumed[index]) continue;
        if (request.id != id) continue;
        if (request.action != action) continue;
        self.accessibility_consumed[index] = true;
        return request;
    }
    return null;
}

fn dupeAccessibilityText(self: *UI, content: []const u8) ![]const u8 {
    if (content.len == 0) return &.{};
    _ = std.unicode.Utf8View.init(content) catch return error.InvalidAccessibilityText;
    return self.allocator.dupe(u8, content);
}

fn freeAccessibilityText(self: *UI, content: []const u8) void {
    if (content.len > 0) self.allocator.free(content);
}

fn freeAccessibilityNode(self: *UI, node: *Accessibility.Node) void {
    Accessibility.freeNodes(self.allocator, node[0..1]);
}

pub fn hovering(self: *UI, id: Element.Id) bool {
    if (!self.inputScopeAllowsId(id)) return false;
    return self.state.hovered == id;
}

pub fn pressing(self: *UI, id: Element.Id) bool {
    if (!self.inputScopeAllowsId(id)) return false;
    return self.state.active == id;
}

pub fn leftPressed(self: *UI, id: Element.Id, target: HitTarget) bool {
    if (!self.inputScopeAllowsId(id)) return false;
    if (!self.input.mouseButton(.left).pressed) return false;
    return matchesHitTarget(self.state.press_origin, self.press_ancestors.items, id, target);
}

pub fn leftClicked(self: *UI, id: Element.Id, target: HitTarget) bool {
    if (!self.inputScopeAllowsId(id)) return false;
    if (!self.input.mouseButton(.left).released) return false;
    if (self.state.press_drag) return false;
    if (!matchesHitTarget(self.state.press_origin, self.press_ancestors.items, id, target)) return false;
    return matchesHitTarget(self.state.hovered, self.hover_ancestors.items, id, target);
}

pub fn focused(self: *UI, id: Element.Id) bool {
    if (!self.inputScopeAllowsId(id)) return false;
    return self.state.focused == id;
}

pub fn isHoveredWithin(self: *UI, ancestor_id: Element.Id) bool {
    if (!self.inputScopeAllowsId(ancestor_id)) return false;
    return self.isDescendantOrSelf(self.state.hovered, ancestor_id);
}

pub fn isFocusedWithin(self: *UI, ancestor_id: Element.Id) bool {
    if (!self.inputScopeAllowsId(ancestor_id)) return false;
    return self.isDescendantOrSelf(self.state.focused, ancestor_id);
}

fn isDescendantOrSelf(self: *UI, descendant_id: Element.Id, ancestor_id: Element.Id) bool {
    if (descendant_id == Element.INVALID_ID) return false;
    if (descendant_id == ancestor_id) return true;
    const ancestor_slot = self.layout_ctx.slotForId(ancestor_id) orelse return false;
    const descendant_slot = self.layout_ctx.slotForId(descendant_id) orelse return false;
    return self.layout_ctx.isDescendantOf(descendant_slot, ancestor_slot);
}

fn matchesHitTarget(hit: Element.Id, ancestors: []const Element.Id, id: Element.Id, target: HitTarget) bool {
    return switch (target) {
        .exact => hit == id,
        .within => std.mem.indexOfScalar(Element.Id, ancestors, id) != null,
        .root => ancestors.len > 0 and ancestors[ancestors.len - 1] == id,
    };
}

fn inputScopeAllowsId(self: *UI, id: Element.Id) bool {
    if (!self.input_scopes.hasActive()) return true;
    if (self.inputScopeForId(id)) |scope| return self.input_scopes.allows(scope);

    const current = self.input_scopes.current();
    return current != Element.INVALID_ID and self.input_scopes.allows(current);
}

fn inputScopeForId(self: *UI, id: Element.Id) ?Element.Id {
    if (id == Element.INVALID_ID) return null;

    if (self.layout_ctx.slotForId(id)) |slot|
        return self.layout_ctx.pool.get(slot).input_scope;

    var i = self.hit_records.items.len;
    while (i > 0) {
        i -= 1;
        const rec = self.hit_records.items[i];
        if (rec.id == id) return rec.input_scope;
    }

    return null;
}

test "anim returns target immediately on first touch" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    ui.input.now_ms = 1000;
    const v = ui.anim(1, "hover", 1.0, .{ .duration_ms = 200 });
    try std.testing.expectApproxEqAbs(v, 1.0, 1e-6);
    try std.testing.expect(!ui.anim_active);
}

test "anim snapshots start_value mid-interruption" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    ui.input.now_ms = 0;
    _ = ui.anim(1, "hover", 0.0, .{ .duration_ms = 200 });

    ui.input.now_ms = 0;
    _ = ui.anim(1, "hover", 1.0, .{ .duration_ms = 200 });

    ui.input.now_ms = 100;
    const midway = ui.anim(1, "hover", 1.0, .{ .duration_ms = 200 });
    try std.testing.expect(midway > 0.0 and midway < 1.0);
    try std.testing.expect(ui.anim_active);

    ui.input.now_ms = 100;
    const reversed_start = ui.anim(1, "hover", 0.0, .{ .duration_ms = 200 });
    try std.testing.expectApproxEqAbs(reversed_start, midway, 1e-6);

    ui.input.now_ms = 150;
    const reversing = ui.anim(1, "hover", 0.0, .{ .duration_ms = 200 });
    try std.testing.expect(reversing < midway);
    try std.testing.expect(reversing > 0.0);
}

test "anim retarget samples elapsed progress before interruption" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    ui.input.now_ms = 0;
    _ = ui.anim(1, "hover", 0.0, .{ .duration_ms = 200 });

    ui.input.now_ms = 0;
    _ = ui.anim(1, "hover", 1.0, .{ .duration_ms = 200 });

    ui.input.now_ms = 100;
    const reversed_start = ui.anim(1, "hover", 0.0, .{ .duration_ms = 200 });
    try std.testing.expectApproxEqAbs(reversed_start, 0.5, 1e-6);

    ui.input.now_ms = 150;
    const reversing = ui.anim(1, "hover", 0.0, .{ .duration_ms = 200 });
    try std.testing.expect(reversing < reversed_start);
    try std.testing.expect(reversing > 0.0);
}

test "anim settles and clears dirty flag" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    ui.input.now_ms = 0;
    _ = ui.anim(1, "hover", 0.0, .{ .duration_ms = 100 });
    ui.input.now_ms = 0;
    _ = ui.anim(1, "hover", 1.0, .{ .duration_ms = 100 });

    ui.anim_active = false;
    ui.input.now_ms = 500;
    const done = ui.anim(1, "hover", 1.0, .{ .duration_ms = 100 });
    try std.testing.expectApproxEqAbs(done, 1.0, 1e-6);
    try std.testing.expect(!ui.anim_active);
}

test "style content is inherited through raw and styled elements" {
    var ui = try UI.init(std.testing.allocator, .{ .theme = Theme.dark });
    defer ui.deinit();

    const parent: style.Style = .{ .foreground = .success, .font_size = .lg, .tone = .warning };
    _ = try ui.openStyled(Key.str("parent"), .{ .base = &parent, .user = &.{} }, .{}, .{});
    _ = try ui.open(Key.str("raw"), .{}, .none);
    const child = try ui.openStyled(Key.str("child"), .{ .base = &.{ .background = .accent }, .user = &.{} }, .{}, .{});
    try std.testing.expectEqual(Theme.dark.success.value, child.resolved.content.foreground);
    try std.testing.expectEqual(Theme.dark.font_size[3], child.resolved.content.font_size);
    try std.testing.expectEqual(Theme.dark.warning.value, child.resolved.surface.color);
    ui.close();
    ui.close();
    ui.close();

    try std.testing.expectEqual(Theme.dark.text.value, ui.parentContent().foreground);
    try std.testing.expectEqual(@as(usize, 3), ui.contents.items.len);
}

test "style transitions interpolate surface changes" {
    var ui = try UI.init(std.testing.allocator, .{ .theme = Theme.dark });
    defer ui.deinit();

    const s: style.Style = .{
        .background = .muted,
        .hover = &.{ .background = .success },
        .transition = .{ .duration_ms = 100, .ease = .smooth_step },
    };
    const cascade: style.Cascade = .{ .base = &s, .user = &.{} };

    ui.input.now_ms = 0;
    const idle = ui.resolveStyle(1, cascade, .{}, null);
    try std.testing.expectEqual(Theme.dark.muted.value, idle.surface.color);
    try std.testing.expect(!ui.anim_active);

    const start = ui.resolveStyle(1, cascade, .{ .hover = true }, null);
    try std.testing.expectEqual(Theme.dark.muted.value, start.surface.color);

    ui.input.now_ms = 50;
    const mid = ui.resolveStyle(1, cascade, .{ .hover = true }, null);
    try std.testing.expect(ui.anim_active);
    try std.testing.expect(!std.meta.eql(mid.surface.color, Theme.dark.muted.value));
    try std.testing.expect(!std.meta.eql(mid.surface.color, Theme.dark.success.value));

    ui.anim_active = false;
    ui.input.now_ms = 500;
    const done = ui.resolveStyle(1, cascade, .{ .hover = true }, null);
    try std.testing.expectEqual(Theme.dark.success.value, done.surface.color);
    try std.testing.expect(!ui.anim_active);
}
