const layout = @import("layout");
const text = @import("text");
const window = @import("window");
const math = @import("math");

const Element = layout.Element;
const std = @import("std");
const gpu = @import("gpu");
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
const Style = @import("Style.zig");
const Size = @import("Size.zig");
const Theme = @import("Theme.zig");
const Radius = @import("Radius.zig");
const BorderWidth = @import("BorderWidth.zig");
const scrollbar = @import("scrollbar.zig");
const canvas_tessellator = @import("canvas_tessellator.zig");

const Allocator = std.mem.Allocator;

pub const INVALID_ID = Element.INVALID_ID;
pub const InputScopeConfig = InputScope.Config;

const INV_SQRT2: f32 = 0.70710677;
const TEXT_QUAD_NORMALS = [4][2]f32{
    .{ -INV_SQRT2, -INV_SQRT2 }, // tl
    .{ INV_SQRT2, -INV_SQRT2 }, // tr
    .{ INV_SQRT2, INV_SQRT2 }, // br
    .{ -INV_SQRT2, INV_SQRT2 }, // bl
};

pub const HitRecord = struct {
    id: Element.Id,
    bounds: math.Rect,
    clip: Clip.State,
    layer: u8,
    input_scope: Element.Id,
    insertion_order: u32,
};

pub const Config = struct {
    /// Default is Roboto regular + Material icons regular.
    fonts: []const text.Font.FontKey = &.{.{ "default", @embedFile("fonts/default.ttf") }},
    /// Per-pool eviction TTLs in frames. Long-lived widget state (cursor,
    /// scroll, dropdown-open, selection) survives conditional hiding (Tabs,
    /// Accordion, Tree); short-lived state (anim) is evicted promptly.
    state_ttls: State.Ttls = .{},
    scroll_line_size: Size.Input = .sm,
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
font: text.Font,
state: State,
input: Input,
hit_records: std.ArrayList(HitRecord),
focus_order: std.ArrayList(Element.Id),
accessibility_nodes: std.ArrayList(Accessibility.Node),
hit_counter: u32,
scroll_geoms: std.ArrayList(scrollbar.SlotGeom),
clip_shapes: std.ArrayList(?Clip.Shape),
slot_clips: std.ArrayList(Clip.State),
child_clips: std.ArrayList(Clip.State),
clip_nodes: std.ArrayList(Clip.Node),
input_scopes: InputScope,
content_scale: f32,
scroll_line_size: Size.Input,
anim_active: bool,
theme: Theme,
last_stats: Stats,
cursor_shape: window.CursorShape,

const UI = @This();

pub fn init(allocator: Allocator, cfg: Config) !UI {
    return .{
        .allocator = allocator,
        .layout_ctx = .init(allocator),
        .decorations = .empty,
        .state = .init(allocator, cfg.state_ttls),
        .input = .{},
        .font = try .init(allocator, cfg.fonts),
        .hit_records = .empty,
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
        .theme = cfg.theme,
        .last_stats = .{},
        .cursor_shape = .default,
    };
}

pub fn deinit(self: *UI) void {
    self.layout_ctx.deinit();
    self.decorations.deinit(self.allocator);
    self.font.deinit();
    self.state.deinit();
    self.hit_records.deinit(self.allocator);
    self.focus_order.deinit(self.allocator);
    self.freeAccessibilityNodes();
    self.accessibility_nodes.deinit(self.allocator);
    self.scroll_geoms.deinit(self.allocator);
    self.clip_shapes.deinit(self.allocator);
    self.slot_clips.deinit(self.allocator);
    self.child_clips.deinit(self.allocator);
    self.clip_nodes.deinit(self.allocator);
    self.input_scopes.deinit(self.allocator);
}

pub fn open(self: *UI, key: Key, element: Element.Config, decoration: Decoration) !Element.Id {
    const id = key.hash();
    try self.decorations.ensureUnusedCapacity(self.allocator, 1);
    try self.clip_shapes.ensureUnusedCapacity(self.allocator, 1);
    if (element.focusable) try self.focus_order.ensureUnusedCapacity(self.allocator, 1);
    const slot = try self.layout_ctx.open(id, element);
    const slot_index: usize = @intCast(slot);
    std.debug.assert(self.decorations.items.len == slot_index);
    std.debug.assert(self.clip_shapes.items.len == slot_index);
    self.decorations.appendAssumeCapacity(decoration);
    self.clip_shapes.appendAssumeCapacity(clipShapeFromDecoration(decoration));
    const el = self.layout_ctx.pool.get(slot);
    el.input_scope = self.input_scopes.current();
    if (decoration == .text) {
        el.intrinsic_w = decoration.text.intrinsic_w;
        el.intrinsic_h = decoration.text.intrinsic_h;
    }
    if (element.focusable) self.focus_order.appendAssumeCapacity(id);
    return id;
}

pub fn close(self: *UI) void {
    self.layout_ctx.close();
}

pub fn openRoot(self: *UI, key: Key, x: f32, y: f32, config: Element.Config, decoration: Decoration) !Element.Id {
    var cfg = config;
    if (self.layout_ctx.stack.items.len > 0) {
        const parent_slot = self.layout_ctx.stack.items[self.layout_ctx.stack.items.len - 1];
        const parent = self.layout_ctx.pool.get(parent_slot);
        cfg.z_index = @max(cfg.z_index, parent.z_index);
    }

    const id = key.hash();
    try self.decorations.ensureUnusedCapacity(self.allocator, 1);
    try self.clip_shapes.ensureUnusedCapacity(self.allocator, 1);
    if (cfg.focusable) try self.focus_order.ensureUnusedCapacity(self.allocator, 1);
    const slot = try self.layout_ctx.openRoot(id, cfg);
    const slot_index: usize = @intCast(slot);
    std.debug.assert(self.decorations.items.len == slot_index);
    std.debug.assert(self.clip_shapes.items.len == slot_index);
    self.decorations.appendAssumeCapacity(decoration);
    self.clip_shapes.appendAssumeCapacity(clipShapeFromDecoration(decoration));
    const el = self.layout_ctx.pool.get(slot);
    el.input_scope = self.input_scopes.current();
    el.box.setX(x);
    el.box.setY(y);
    if (decoration == .text) {
        el.intrinsic_w = decoration.text.intrinsic_w;
        el.intrinsic_h = decoration.text.intrinsic_h;
    }
    if (cfg.focusable) self.focus_order.appendAssumeCapacity(id);
    return id;
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

/// Open an absolutely-positioned element inside the current parent at parent-local
/// offset (x, y) with size (w, h). The caller still pairs this with `close()`.
/// Use this for overlay rects (cursor, selection, drag handles, tab indicators)
/// that need precise placement on top of sibling content without escaping the parent.
/// For popups that need to escape clipping or the layout tree, use `openRoot`.
pub fn openAt(self: *UI, key: Key, x: f32, y: f32, w: f32, h: f32, config: Element.Config, decoration: Decoration) !Element.Id {
    var cfg = config;
    cfg.position = .absolute;
    cfg.width = .fixed(w);
    cfg.height = .fixed(h);
    cfg.offset = .{ x, y };
    return self.open(key, cfg, decoration);
}

pub fn beginInputScope(self: *UI, id: Element.Id, config: InputScopeConfig) !void {
    const slot = self.layout_ctx.slotForId(id) orelse unreachable;
    const el = self.layout_ctx.pool.get(slot);
    try self.input_scopes.begin(self.allocator, id, config, el.z_index);
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

pub fn lineHeight(self: *UI, size: Size, font: ?[]const u8) !f32 {
    const face = try self.font.getFace(font);
    const scale = self.content_scale;
    return (try face.lineHeight(size.value * scale)) / scale;
}

pub fn scrollLineHeight(self: *UI) !f32 {
    return self.lineHeight(self.scroll_line_size.resolve(), null);
}

pub fn textDecoration(self: *UI, content: []const u8, size: Size, font: ?[]const u8, wrap: bool) !Decoration {
    const face = try self.font.getFace(font);
    const scale = self.content_scale;
    if (wrap) {
        const lh = (try face.lineHeight(size.value * scale)) / scale;
        return .{ .text = .{
            .content = content,
            .size = size.value,
            .font = font,
            .intrinsic_w = 0,
            .intrinsic_h = lh,
            .wrap = true,
        } };
    }
    const measured = try face.measure(content, size.value * scale);
    return .{ .text = .{
        .content = content,
        .size = size.value,
        .font = font,
        .intrinsic_w = measured.width / scale,
        .intrinsic_h = measured.height / scale,
        .wrap = false,
    } };
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
    self.clip_shapes.clearRetainingCapacity();
    self.hit_records.clearRetainingCapacity();
    self.focus_order.clearRetainingCapacity();
    self.freeAccessibilityNodes();
    self.accessibility_nodes.clearRetainingCapacity();
    self.hit_counter = 0;
    self.scroll_geoms.clearRetainingCapacity();
    self.slot_clips.clearRetainingCapacity();
    self.child_clips.clearRetainingCapacity();
    self.clip_nodes.clearRetainingCapacity();
    self.input_scopes.resetFrame();
    self.anim_active = false;
    self.cursor_shape = .default;
}

pub fn requestCursor(self: *UI, shape: window.CursorShape) void {
    self.cursor_shape = shape;
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
    self.syncAccessibility();
}

pub fn setAccessibility(self: *UI, id: Element.Id, meta: Accessibility.Metadata) !void {
    if (id == Element.INVALID_ID) return;

    const name = try self.dupeAccessibilityText(meta.name);
    errdefer self.freeAccessibilityText(name);
    var state = meta.state;
    if (meta.state.value_text) |value| {
        state.value_text = try self.dupeAccessibilityText(value);
    }
    errdefer if (state.value_text) |value| self.freeAccessibilityText(value);

    for (self.accessibility_nodes.items) |*node| {
        if (node.id == id) {
            self.freeAccessibilityNode(node);
            node.role = meta.role;
            node.name = name;
            node.state = state;
            return;
        }
    }
    try self.accessibility_nodes.append(self.allocator, .{
        .id = id,
        .role = meta.role,
        .name = name,
        .state = state,
    });
}

/// The returned nodes and their text remain valid until the next `reset`.
pub fn accessibilitySnapshot(self: *const UI) []const Accessibility.Node {
    return self.accessibility_nodes.items;
}

fn dupeAccessibilityText(self: *UI, content: []const u8) ![]const u8 {
    if (content.len == 0) return &.{};
    return self.allocator.dupe(u8, content);
}

fn freeAccessibilityText(self: *UI, content: []const u8) void {
    if (content.len > 0) self.allocator.free(content);
}

fn freeAccessibilityNode(self: *UI, node: *Accessibility.Node) void {
    self.freeAccessibilityText(node.name);
    if (node.state.value_text) |value| self.freeAccessibilityText(value);
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

pub fn leftClicked(self: *UI, id: Element.Id) bool {
    if (!self.inputScopeAllowsId(id)) return false;
    return self.input.mouseButton(.left).pressed and self.state.press_origin == id;
}

pub fn focused(self: *UI, id: Element.Id) bool {
    if (!self.inputScopeAllowsId(id)) return false;
    return self.state.focused == id;
}

pub fn selectionText(self: *UI) ?[]const u8 {
    if (self.state.selection_text.len == 0) return null;
    return self.state.selection_text;
}

pub fn isHoveredWithin(self: *UI, ancestor_id: Element.Id) bool {
    if (!self.inputScopeAllowsId(ancestor_id)) return false;
    return self.isDescendantOrSelf(self.state.hovered, ancestor_id);
}

pub fn isFocusedWithin(self: *UI, ancestor_id: Element.Id) bool {
    if (!self.inputScopeAllowsId(ancestor_id)) return false;
    return self.isDescendantOrSelf(self.state.focused, ancestor_id);
}

pub fn leftClickedWithin(self: *UI, ancestor_id: Element.Id) bool {
    if (!self.inputScopeAllowsId(ancestor_id)) return false;
    if (!self.input.mouseButton(.left).released) return false;
    if (self.state.press_drag) return false;
    if (!self.isDescendantOrSelf(self.state.press_origin, ancestor_id)) return false;
    return self.isDescendantOrSelf(self.state.hovered, ancestor_id);
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

pub fn resolveWindow(self: *UI, input: window.Input, now_ms: i64, content_scale: f32) !void {
    self.content_scale = content_scale;
    self.state.selection_text = &.{};
    self.input.collect(input, now_ms);

    if (self.input.focus_lost or self.input.pointer_cancelled) {
        self.state.active = Element.INVALID_ID;
        self.state.press_origin = Element.INVALID_ID;
        self.state.press_drag = false;
    }

    if (self.layout_ctx.has_scroll) try scrollbar.route(self);

    if (self.input_scopes.hasActive()) {
        if (!self.inputScopeAllowsId(self.state.hovered)) self.state.hovered = Element.INVALID_ID;
        if (!self.inputScopeAllowsId(self.state.focused)) self.state.focused = Element.INVALID_ID;
        if (!self.inputScopeAllowsId(self.state.active)) self.state.active = Element.INVALID_ID;
        if (!self.inputScopeAllowsId(self.state.press_origin)) self.state.press_origin = Element.INVALID_ID;
    }

    if (self.input.containsKey(.tab)) {
        self.advanceFocus(self.input.shift_held);
        self.input.consumeKeyboard();
    }

    self.state.hovered = self.currentMouseHit();

    if (self.input.mouseButton(.left).pressed) {
        const press_pos = self.input.mouseButton(.left).pressed_pos orelse self.input.mouse_pos;
        const press_hit = self.mouseHit(press_pos);
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

fn syncAccessibility(self: *UI) void {
    for (self.accessibility_nodes.items) |*node| {
        const slot = self.layout_ctx.slotForId(node.id) orelse continue;
        const el = self.layout_ctx.pool.get(slot);
        node.bounds = el.box;
        node.state.focused = node.id == self.state.focused;
        node.parent = if (el.parent == Element.INVALID_SLOT)
            Element.INVALID_ID
        else
            self.layout_ctx.pool.get(el.parent).id;
    }
}

fn advanceFocus(self: *UI, backward: bool) void {
    const order = self.focus_order.items;
    if (order.len == 0) {
        self.state.focused = Element.INVALID_ID;
        self.state.active = Element.INVALID_ID;
        return;
    }

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
        if (self.inputScopeAllowsId(id)) {
            self.state.focused = id;
            self.state.active = Element.INVALID_ID;
            return;
        }
    }
}

/// Advance the per widget state TTL clock. Call once per frame after the
/// users frame callback has had a chance to touch its state, otherwise
/// entries lose a frame of TTL grace before the sweep sees them.
pub fn endFrame(self: *UI, host: *window.Window) !void {
    try self.state.endFrame();
    self.input_scopes.resolveActive();
    host.setCursorShape(self.cursor_shape);
}

const press_drag_threshold_sq: f64 = 9.0;

fn clearOtherTextSelect(hovered: Element.Id, id: Element.Id, s: *State.TextSelect) void {
    if (id == hovered) return;
    s.anchor_byte = 0;
    s.cursor_byte = 0;
    s.dragging = false;
}

pub fn appendHit(self: *UI, id: Element.Id, bounds: math.Rect, clip: Clip.State, layer: u8) !void {
    try self.appendHitWithScope(id, bounds, clip, layer, self.inputScopeForId(id) orelse Element.INVALID_ID);
}

pub fn appendHitWithScope(self: *UI, id: Element.Id, bounds: math.Rect, clip: Clip.State, layer: u8, input_scope: Element.Id) !void {
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

fn hitTarget(self: *UI, p: math.Vec2) Element.Id {
    var best_id: Element.Id = Element.INVALID_ID;
    var best_layer: u8 = 0;
    var best_order: u32 = 0;

    for (self.hit_records.items) |rec| {
        if (!rec.bounds.contains(p)) continue;
        if (!Clip.contains(rec.clip, self.clip_nodes.items, p)) continue;
        if (!self.input_scopes.allows(rec.input_scope)) continue;

        if (best_id == Element.INVALID_ID or
            rec.layer > best_layer or
            (rec.layer == best_layer and rec.insertion_order > best_order))
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
        draw_list.setLayer(@intCast(z));
        try self.tessellateLayer(allocator, draw_list, self.layout_ctx.zSlots(@intCast(z)), @intCast(z));
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

fn tessellateLayer(self: *UI, allocator: Allocator, draw_list: *DrawList, slots: []const Element.Slot, layer: u8) !void {
    const content_scale = self.content_scale;
    const elements = self.layout_ctx.pool.elements.items;

    for (slots) |slot| {
        const el = &elements[slot];

        const clip = self.slot_clips.items[slot];
        const clipped_out = if (clip.scissor) |c| !c.overlaps(el.box) else false;
        if (clipped_out) continue;

        if (el.overflow.isScroll()) try scrollbar.recordForTessellate(self, slot, clip, layer);

        if (el.interactive) try self.appendHitWithScope(el.id, el.box, clip, layer, el.input_scope);

        switch (self.decorations.items[slot]) {
            .none => {},
            .rect => |r| {
                const inst = gpu.Instance{
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
                try draw_list.pushInstances(&[_]gpu.Instance{inst}, null, clip);
            },
            .text => |t| if (t.content.len > 0) {
                const face = try self.font.getFace(t.font);
                const wrap_px: f32 = if (t.wrap) @max(0, el.box.w() * content_scale) else 0;
                const shaped = try face.shapeWrapped(t.content, t.size * content_scale, wrap_px);
                if (shaped.lines.len > 0) {
                    const ascender = shaped.ascender / content_scale;
                    const size_logical = t.size;

                    const inv_size = 1.0 / size_logical;
                    const jac = [4]f32{ inv_size, 0, 0, -inv_size };

                    var total_glyphs: usize = 0;
                    for (shaped.lines) |ln| total_glyphs += ln.glyphs.len;
                    if (total_glyphs == 0) continue;

                    const batch = (try draw_list.beginTextBatch(total_glyphs, clip)).?;

                    for (shaped.lines) |line| {
                        const baseline = el.box.y() + ascender + line.y / content_scale;
                        for (line.glyphs) |gl| {
                            const rec = gl.record;
                            if (rec.is_empty) continue;

                            const em_x: math.Vec4 = .{ rec.em_min[0], rec.em_max[0], rec.em_max[0], rec.em_min[0] };
                            const em_y: math.Vec4 = .{ rec.em_max[1], rec.em_max[1], rec.em_min[1], rec.em_min[1] };
                            const size_v: math.Vec4 = @splat(size_logical);
                            const origin_x_v: math.Vec4 = @splat(el.box.x() + gl.x / content_scale);
                            const baseline_v: math.Vec4 = @splat(baseline);

                            const sx_v = origin_x_v + em_x * size_v;
                            const sy_v = baseline_v - em_y * size_v;

                            if (clip.scissor) |c| {
                                const dilation_margin = 2.0 / content_scale;
                                const glyph_bounds = math.Rect.fromMinMax(
                                    .{ @reduce(.Min, sx_v), @reduce(.Min, sy_v) },
                                    .{ @reduce(.Max, sx_v), @reduce(.Max, sy_v) },
                                ).expand(dilation_margin);
                                if (!c.overlaps(glyph_bounds)) continue;
                            }

                            const tex_z_bits: u32 =
                                @as(u32, rec.glyph_loc_x) | (@as(u32, rec.glyph_loc_y) << 16);
                            const tex_w_bits: u32 =
                                @as(u32, rec.band_max_x) | (@as(u32, rec.band_max_y) << 16);
                            const tex_z: f32 = @bitCast(tex_z_bits);
                            const tex_w: f32 = @bitCast(tex_w_bits);

                            const bnd = [4]f32{
                                rec.band_scale[0],  rec.band_scale[1],
                                rec.band_offset[0], rec.band_offset[1],
                            };

                            var verts: [4]gpu.SlugVertex = undefined;
                            inline for (0..4) |ci| {
                                verts[ci] = .{
                                    .pos = .{
                                        sx_v[ci],
                                        sy_v[ci],
                                        TEXT_QUAD_NORMALS[ci][0],
                                        TEXT_QUAD_NORMALS[ci][1],
                                    },
                                    .tex = .{ em_x[ci], em_y[ci], tex_z, tex_w },
                                    .jac = jac,
                                    .bnd = bnd,
                                    .col = t.color,
                                };
                            }
                            try draw_list.pushTextQuad(batch, verts);
                        }
                    }
                }
            },
            .canvas => |c| try canvas_tessellator.tessellate(allocator, draw_list, c.cmds, .{ el.box.x(), el.box.y() }, clip),
            .image => |img| {
                const zero4 = [4]f32{ 0, 0, 0, 0 };
                const inst = gpu.Instance{
                    .pos = .{ el.box.x(), el.box.y() },
                    .size = .{ el.box.w(), el.box.h() },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 1, 1 },
                    .color = img.tint,
                    .border_color = zero4,
                    .corner_radius = Radius.zero.value,
                    .border_width = BorderWidth.zero.value,
                    .prim_type = 2.0,
                };
                try draw_list.pushInstances(&[_]gpu.Instance{inst}, img.texture_id, clip);
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
    try draw_list.pushInstances(&[_]gpu.Instance{track}, null, clip);

    if (progress > 0) {
        const fill = solidRectInstance(bx, ty, bw * progress, th, r.fill_color, r.corner_radius);
        try draw_list.pushInstances(&[_]gpu.Instance{fill}, null, clip);
    }

    if (r.halo_radius > 0 and r.halo_color[3] > 0) {
        const hr = r.halo_radius;
        const cx = bx + bw * progress;
        const cy = by + bh * 0.5;
        const halo = solidRectInstance(cx - hr, cy - hr, hr * 2, hr * 2, r.halo_color, Radius.all(hr));
        try draw_list.pushInstances(&[_]gpu.Instance{halo}, null, clip);
    }

    if (r.knob_radius > 0) {
        const kr = r.knob_radius;
        const cx = bx + bw * progress;
        const cy = by + bh * 0.5;
        const knob = solidRectInstance(cx - kr, cy - kr, kr * 2, kr * 2, r.knob_color, Radius.all(kr));
        try draw_list.pushInstances(&[_]gpu.Instance{knob}, null, clip);
    }
}

inline fn solidRectInstance(x: f32, y: f32, w: f32, h: f32, color: [4]f32, corner_radius: Radius) gpu.Instance {
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

    try ui.appendHit(42, .init(0, 0, 100, 100), .{}, 0);

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
