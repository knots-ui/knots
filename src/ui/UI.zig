const input_types = @import("input");
const layout = @import("layout");
const text = @import("text");
const math = @import("math");

const Element = layout.Element;
const std = @import("std");
const types = @import("render_types");
const render = @import("render");
const DrawList = render.DrawList;
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
const Radius = style.Radius;
const BorderWidth = style.BorderWidth;
const Layer = layout.Layer;
const scrollbar = @import("scrollbar.zig");
const canvas_tessellator = @import("canvas_tessellator.zig");

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
    self.freeAccessibilityNodes();
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

pub fn reset(self: *UI) void {
    self.layout_ctx.reset();
    self.decorations.clearRetainingCapacity();
    self.contents.clearRetainingCapacity();
    self.clip_shapes.clearRetainingCapacity();
    self.hit_records.clearRetainingCapacity();
    self.focus_order.clearRetainingCapacity();
    self.freeAccessibilityNodes();
    self.accessibility_nodes.clearRetainingCapacity();
    self.accessibility_children.clearRetainingCapacity();
    self.accessibility_node_indices.clearRetainingCapacity();
    self.hit_counter = 0;
    self.scroll_geoms.clearRetainingCapacity();
    self.slot_clips.clearRetainingCapacity();
    self.child_clips.clearRetainingCapacity();
    self.clip_nodes.clearRetainingCapacity();
    self.input_scopes.resetFrame();
    self.anim_active = false;
    self.text_input_requested = false;
    self.cursor_shape = .default;
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

pub fn resolve(self: *UI) !void {
    if (self.layout_ctx.root_slot == Element.INVALID_SLOT) {
        try self.layout_ctx.buildZOrder();
        self.updateStats();
        try self.syncAccessibility();
        return;
    }

    const scroll: layout.Context.ScrollLookup = .{
        .ctx = @ptrCast(&self.state),
        .getFn = @ptrCast(&State.getScroll),
    };

    self.layout_ctx.computeSizes();
    try self.layout_ctx.computeLayout(scroll, self.theme.scrollbar_thickness);

    // After a first layout pass, recompute intrinsic_h for every wrap-text element using its just-assigned box width.
    if (try self.reflowWrappedText()) {
        self.layout_ctx.computeSizes();
        try self.layout_ctx.computeLayout(scroll, self.theme.scrollbar_thickness);
    }

    try self.layout_ctx.buildZOrder();
    self.syncStateBounds();
    try self.syncAccessibility();
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
        self.accessibility_nodes.appendAssumeCapacity(rootAccessibilityNode());
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

pub fn semanticSnapshot(self: *const UI) Accessibility.Snapshot {
    const nodes = self.accessibility_nodes.items;
    return .{
        .content_scale = self.content_scale,
        .nodes = nodes,
        .children = self.accessibility_children.items,
        .focus = if (self.state.focused != Element.INVALID_ID and self.hasAccessibilityNode(self.state.focused)) self.state.focused else Accessibility.root_id,
    };
}

fn hasAccessibilityNode(self: *const UI, id: Element.Id) bool {
    return self.accessibility_node_indices.contains(id);
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
    self.freeAccessibilityText(node.name);
    if (node.state.value_text) |value| self.freeAccessibilityText(value);
}

fn rootAccessibilityNode() Accessibility.Node {
    return .{ .id = Accessibility.root_id, .role = .generic };
}

fn freeAccessibilityNodes(self: *UI) void {
    for (self.accessibility_nodes.items) |*node| self.freeAccessibilityNode(node);
}

/// Returns true if any height changed, in which case the caller should re-run layout so ancestors fit the new heights.
fn reflowWrappedText(self: *UI) !bool {
    var changed = false;
    for (self.decorations.items, 0..) |dec, slot| {
        if (dec != .text) continue;
        const t = dec.text;
        if (!t.wrap or t.content.len == 0) continue;

        const el = self.layout_ctx.pool.get(@intCast(slot));
        const wrap_px = el.box.w() * self.content_scale;
        if (wrap_px <= 0) continue;

        const face = try self.font.getFace(t.font);
        const shaped = try face.shapeWrapped(t.content, t.size * self.content_scale, wrap_px);
        const new_h = shaped.height / self.content_scale;
        if (new_h != el.intrinsic_h) {
            el.intrinsic_h = new_h;
            changed = true;
        }
    }
    return changed;
}

fn syncStateBounds(self: *UI) void {
    if (self.layout_ctx.root_slot == Element.INVALID_SLOT) return;
    const root_box = self.layout_ctx.pool.get(self.layout_ctx.root_slot).box;
    for (self.layout_ctx.pool.elements.items) |el| {
        if (self.state.get(.text_select, el.id)) |s| s.box = el.box;
        if (self.state.get(.slider, el.id)) |s| s.bounds = el.box;
        if (self.state.get(.measured, el.id)) |s| {
            s.box = el.box;
            s.width = el.box.w();
            s.height = el.box.h();
        }
        if (self.state.get(.resize, el.id)) |s| s.box = el.box;
        if (self.state.get(.select_input, el.id)) |s| {
            s.anchor_box = el.box;
            s.viewport_box = root_box;
        }
        if (self.state.get(.color_picker, el.id)) |s| {
            s.anchor_box = el.box;
            s.viewport_box = root_box;
        }
        if (self.state.get(.context_menu, el.id)) |s| {
            s.anchor_box = el.box;
            s.viewport_box = root_box;
        }
        if (self.state.get(.menu_button, el.id)) |s| {
            s.anchor_box = el.box;
            s.viewport_box = root_box;
        }
        if (self.state.get(.tooltip, el.id)) |s| {
            s.anchor_box = el.box;
            s.viewport_box = root_box;
        }
    }
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

fn currentMouseHit(self: *UI) Element.Id {
    return self.mouseHit(self.input.mouse_pos);
}

fn mouseHit(self: *UI, pos: [2]f64) Element.Id {
    return self.hitTarget(.{ @floatCast(pos[0]), @floatCast(pos[1]) });
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

fn captureHitAncestors(allocator: Allocator, layout_ctx: *layout.Context, id: Element.Id, out: *std.ArrayList(Element.Id)) !void {
    out.clearRetainingCapacity();
    var slot = layout_ctx.slotForId(id) orelse return;
    while (slot != Element.INVALID_SLOT) {
        const el = layout_ctx.pool.get(slot);
        try out.append(allocator, el.id);
        slot = el.parent;
    }
}

pub fn resolveWindow(self: *UI, input: input_types.Input, now_ms: i64, content_scale: f32) !void {
    self.content_scale = content_scale;
    self.state.selection_text = &.{};
    self.input.collect(input, now_ms);

    if (self.input.focus_lost or self.input.pointer_cancelled) {
        self.state.active = Element.INVALID_ID;
        self.state.press_origin = Element.INVALID_ID;
        self.press_ancestors.clearRetainingCapacity();
        self.state.press_drag = false;
    }

    if (self.layout_ctx.has_scroll) try scrollbar.route(self);

    if (self.input_scopes.hasActive()) {
        if (!self.inputScopeAllowsId(self.state.hovered)) self.state.hovered = Element.INVALID_ID;
        if (!self.inputScopeAllowsId(self.state.focused)) self.state.focused = Element.INVALID_ID;
        if (!self.inputScopeAllowsId(self.state.active)) self.state.active = Element.INVALID_ID;
        if (!self.inputScopeAllowsId(self.state.press_origin)) {
            self.state.press_origin = Element.INVALID_ID;
            self.press_ancestors.clearRetainingCapacity();
        }
    }

    if (self.input.containsKey(.tab)) {
        self.advanceFocus(self.input.shift_held);
        self.input.consumeKeyboard();
    }

    self.state.hovered = self.currentMouseHit();
    try captureHitAncestors(self.allocator, &self.layout_ctx, self.state.hovered, &self.hover_ancestors);

    if (self.input.mouseButton(.left).pressed) {
        const press_pos = self.input.mouseButton(.left).pressed_pos orelse self.input.mouse_pos;
        const press_hit = self.mouseHit(press_pos);
        try captureHitAncestors(self.allocator, &self.layout_ctx, press_hit, &self.press_ancestors);
        self.state.active = press_hit;
        self.state.focused = press_hit;
        self.state.press_origin = press_hit;
        self.state.press_pos = press_pos;
        self.state.press_drag = false;

        self.state.forEach(.text_select, press_hit, clearOtherTextSelect);
    }
    if (self.input.mouseButton(.left).down and !self.state.press_drag) {
        const dx = self.input.mouse_pos[0] - self.state.press_pos[0];
        const dy = self.input.mouse_pos[1] - self.state.press_pos[1];
        if (dx * dx + dy * dy > press_drag_threshold_sq) self.state.press_drag = true;
    }
    if (self.input.mouseButton(.left).released and !self.input.mouseButton(.left).down) self.state.active = Element.INVALID_ID;
}

fn syncAccessibility(self: *UI) !void {
    if (self.accessibility_nodes.items.len == 0) {
        try self.accessibility_nodes.ensureUnusedCapacity(self.allocator, 1);
        try self.accessibility_node_indices.ensureUnusedCapacity(self.allocator, 1);
        self.accessibility_nodes.appendAssumeCapacity(rootAccessibilityNode());
        self.accessibility_node_indices.putAssumeCapacity(Accessibility.root_id, 0);
    }
    const count: u32 = @intCast(self.accessibility_nodes.items.len);
    if (count > Accessibility.nodes_max) return error.TooManyAccessibilityNodes;
    self.accessibility_nodes.items[0].bounds = if (self.layout_ctx.root_slot == Element.INVALID_SLOT)
        .zero
    else
        self.layout_ctx.pool.get(self.layout_ctx.root_slot).box;
    std.debug.assert(self.accessibility_nodes.items[0].id == Accessibility.root_id);
    std.debug.assert(self.accessibility_node_indices.get(Accessibility.root_id) != null);
    for (self.accessibility_nodes.items[1..]) |*node| {
        const slot = self.layout_ctx.slotForId(node.id);
        if (slot) |element_slot| {
            const element = self.layout_ctx.pool.get(element_slot);
            node.bounds = element.box;
            node.state.focused = node.id == self.state.focused;
        }
        if (node.parent == Element.INVALID_ID) {
            node.parent = Accessibility.root_id;
            if (slot) |element_slot| {
                var parent_slot = self.layout_ctx.pool.get(element_slot).parent;
                var traversed: u32 = 0;
                const slot_count: u32 = @intCast(self.layout_ctx.pool.elements.items.len);
                while (parent_slot != Element.INVALID_SLOT and traversed < slot_count) : (traversed += 1) {
                    const parent = self.layout_ctx.pool.get(parent_slot);
                    if (self.accessibility_node_indices.contains(parent.id)) {
                        node.parent = parent.id;
                        break;
                    }
                    parent_slot = parent.parent;
                }
                std.debug.assert(traversed <= slot_count);
            }
        } else {
            const parent_index = self.accessibility_node_indices.get(node.parent) orelse return error.InvalidAccessibilityParent;
            if (slot == null) node.bounds = self.accessibility_nodes.items[parent_index].bounds;
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
    const nodes = self.accessibility_nodes.items;
    for (nodes[1..]) |node| {
        const parent_index = self.accessibility_node_indices.get(node.parent) orelse unreachable;
        nodes[parent_index].child_count += 1;
    }
    var offset: u32 = 0;
    for (nodes) |*node| {
        node.child_start = offset;
        offset += node.child_count;
    }
    std.debug.assert(offset == count - 1);
    try self.accessibility_children.resize(self.allocator, offset);
    var cursors: [Accessibility.nodes_max]u32 = @splat(0);
    for (nodes[1..]) |node| {
        const parent_index = self.accessibility_node_indices.get(node.parent) orelse unreachable;
        const child_index = nodes[parent_index].child_start + cursors[parent_index];
        self.accessibility_children.items[child_index] = node.id;
        cursors[parent_index] += 1;
    }
}

fn advanceFocus(self: *UI, backward: bool) void {
    const order = self.focus_order.items;
    if (order.len == 0) {
        self.state.focused = Element.INVALID_ID;
        self.state.active = Element.INVALID_ID;
        return;
    }
    const front_floating = if (self.input_scopes.hasActive()) null else self.state.frontFloatingWindow();

    var current_index: ?usize = null;
    for (order, 0..) |id, i| {
        if (id == self.state.focused) {
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
        if (!self.inputScopeAllowsId(id)) continue;
        if (front_floating) |root_id| {
            if (!self.isDescendantOrSelf(id, root_id)) continue;
        }

        self.state.focused = id;
        self.state.active = Element.INVALID_ID;
        return;
    }

    self.state.focused = Element.INVALID_ID;
    self.state.active = Element.INVALID_ID;
}

/// Advance the per widget state TTL clock. Call once per frame after the
/// users frame callback has had a chance to touch its state, otherwise
/// entries lose a frame of TTL grace before the sweep sees them.
pub fn endFrame(self: *UI) !void {
    try self.state.endFrame();
    self.input_scopes.resolveActive();
}

const press_drag_threshold_sq: f64 = 9.0;

fn clearOtherTextSelect(hovered: Element.Id, id: Element.Id, s: *State.TextSelect) void {
    if (id == hovered) return;
    s.anchor_byte = 0;
    s.cursor_byte = 0;
    s.dragging = false;
}

pub fn appendHit(self: *UI, id: Element.Id, bounds: math.Rect, clip: Clip.State, layer: Layer, input_scope: Element.Id) !void {
    try self.hit_records.append(self.allocator, .{
        .id = id,
        .bounds = bounds,
        .clip = clip,
        .layer = layer,
        .input_scope = input_scope,
        .insertion_order = self.hit_counter,
    });
    self.hit_counter += 1;
}

pub fn resolveHit(self: *UI) bool {
    const best_id = self.currentMouseHit();
    const changed = self.state.hovered != best_id;
    self.state.hovered = best_id;
    self.updateStats();
    return changed;
}

pub fn hitLayerAt(self: *UI, point: math.Vec2) ?Layer {
    var best: ?HitRecord = null;
    for (self.hit_records.items) |record| {
        if (!record.bounds.contains(point)) continue;
        if (!Clip.contains(record.clip, self.clip_nodes.items, point)) continue;
        if (!self.input_scopes.allows(record.input_scope)) continue;
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

fn hitTarget(self: *UI, p: math.Vec2) Element.Id {
    var best_id: Element.Id = Element.INVALID_ID;
    var best_layer: Layer = Layer.base;
    var best_order: u32 = 0;

    for (self.hit_records.items) |rec| {
        if (!rec.bounds.contains(p)) continue;
        if (!Clip.contains(rec.clip, self.clip_nodes.items, p)) continue;
        if (!self.input_scopes.allows(rec.input_scope)) continue;

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

fn updateStats(self: *UI) void {
    self.last_stats = .{
        .elements = self.layout_ctx.pool.elements.items.len,
        .hit_records = self.hit_records.items.len,
        .scroll_containers = self.layout_ctx.scroll_slots.items.len,
        .decorations = self.decorations.items.len,
        .layers = self.layout_ctx.z_used.count(),
    };
}

pub fn tessellate(self: *UI, allocator: Allocator, draw_list: *DrawList) !void {
    defer self.font.endFrame();

    try self.buildClipStates();
    try draw_list.clip_nodes.appendSlice(draw_list.allocator, self.clip_nodes.items);

    var it = self.layout_ctx.z_used.iterator(.{});
    while (it.next()) |z| {
        const layer = Layer.fromIndex(z);
        draw_list.setLayer(layer.index());
        try self.tessellateLayer(allocator, draw_list, self.layout_ctx.zSlots(layer.index()), layer);
    }
}

fn buildClipStates(self: *UI) !void {
    const elements = self.layout_ctx.pool.elements.items;

    self.slot_clips.clearRetainingCapacity();
    self.child_clips.clearRetainingCapacity();
    self.clip_nodes.clearRetainingCapacity();

    try self.slot_clips.resize(self.allocator, elements.len);
    try self.child_clips.resize(self.allocator, elements.len);
    try self.clip_nodes.append(self.allocator, Clip.Node.empty);

    for (elements, 0..) |*el, idx| {
        const parent_clip = if (el.parent != Element.INVALID_SLOT)
            self.child_clips.items[el.parent]
        else
            Clip.State{};

        self.slot_clips.items[idx] = parent_clip;
        self.child_clips.items[idx] = try self.childClip(@intCast(idx), parent_clip);
    }
}

fn childClip(self: *UI, slot: Element.Slot, parent_clip: Clip.State) !Clip.State {
    const el = &self.layout_ctx.pool.elements.items[slot];
    if (el.overflow == .visible) return parent_clip;

    var clip_rect = el.box;
    var radii: math.Vec4 = @splat(0);
    var has_rounding = false;

    if (self.clip_shapes.items[slot]) |shape| {
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
        if (Clip.depth(self.clip_nodes.items, out.node) >= Clip.MAX_DEPTH) return error.ClipStackTooDeep;
        const node_index: u32 = @intCast(self.clip_nodes.items.len);
        try self.clip_nodes.append(self.allocator, .{
            .rect = clip_rect.v,
            .radii = radii,
            .parent = out.node,
            ._pad = .{ 0, 0, 0 },
        });
        out.node = node_index;
    }

    return out;
}

fn tessellateLayer(self: *UI, allocator: Allocator, draw_list: *DrawList, slots: []const Element.Slot, layer: Layer) !void {
    const content_scale = self.content_scale;
    const elements = self.layout_ctx.pool.elements.items;

    for (slots) |slot| {
        const el = &elements[slot];

        const clip = self.slot_clips.items[slot];
        const clipped_out = if (clip.scissor) |c| !c.overlaps(el.box) else false;
        if (clipped_out) continue;

        if (el.overflow.isScroll()) try scrollbar.recordForTessellate(self, slot, clip, layer);

        if (el.interactive) try self.appendHit(el.id, el.box, clip, layer, el.input_scope);

        switch (self.decorations.items[slot]) {
            .none => {},
            .rect => |r| {
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
                const face = try self.font.getFace(t.font);
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

    try scrollbar.render(self, draw_list, layer);
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

        try ui.resolve();
    }

    try ui.resolveWindow(.{
        .pos = .{ 150, 100 },
        .scroll = .{ .pixel = .{ 0, 50 } },
        .chars = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0, 0);
    ui.reset();

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

        try ui.resolve();
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

test "accessibility root stays first across frames" {
    var ui = try UI.init(std.testing.allocator, .{});
    defer ui.deinit();

    try ui.resolve();
    try std.testing.expectEqual(@as(usize, 1), ui.accessibility_nodes.items.len);
    try std.testing.expect(ui.accessibility_node_indices.contains(Accessibility.root_id));

    ui.reset();
    try ui.setAccessibility(42, .{ .role = .button, .name = "First" });
    try ui.setAccessibility(42, .{ .role = .button, .name = "Updated" });
    try ui.resolve();

    try std.testing.expectEqual(@as(usize, 2), ui.accessibility_nodes.items.len);
    try std.testing.expectEqual(Accessibility.root_id, ui.accessibility_nodes.items[0].id);
    try std.testing.expectEqual(@as(Element.Id, 42), ui.accessibility_nodes.items[1].id);
    try std.testing.expectEqualStrings("Updated", ui.accessibility_nodes.items[1].name);

    ui.reset();
    try ui.setAccessibility(43, .{ .role = .button, .name = "Next frame" });
    try ui.resolve();

    try std.testing.expectEqual(@as(usize, 2), ui.accessibility_nodes.items.len);
    try std.testing.expectEqual(Accessibility.root_id, ui.accessibility_nodes.items[0].id);
    try std.testing.expectEqual(@as(Element.Id, 43), ui.accessibility_nodes.items[1].id);
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

test "resolveHit reports hover changes" {
    const allocator = std.testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    try ui.appendHit(42, .init(0, 0, 100, 100), .{}, Layer.base, Element.INVALID_ID);

    ui.input.mouse_pos = .{ 10, 10 };
    try std.testing.expect(ui.resolveHit());
    try std.testing.expectEqual(@as(Element.Id, 42), ui.state.hovered);

    try std.testing.expect(!ui.resolveHit());

    ui.input.mouse_pos = .{ 200, 200 };
    try std.testing.expect(ui.resolveHit());
    try std.testing.expectEqual(Element.INVALID_ID, ui.state.hovered);
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
