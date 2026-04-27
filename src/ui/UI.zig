const layout = @import("layout");
const text = @import("text");
const Window = @import("window").Window;

const Element = layout.Element;
const std = @import("std");
const gpu = @import("gpu");
const DrawList = @import("render").DrawList;

const State = @import("State.zig");
const Input = @import("Input.zig");
const animation = @import("animation.zig");

pub const Decoration = @import("decoration.zig").Decoration;
pub const Key = @import("Key.zig");
pub const Style = @import("Style.zig");

pub const AnimOpts = struct {
    duration_ms: u32 = 150,
    ease: animation.Ease = .smooth_step,
};

const Allocator = std.mem.Allocator;

pub const HitRecord = struct {
    id: Element.Id,
    bounds: [4]f32,
    clip: ?[4]f32,
    layer: u8,
    insertion_order: u32,
};

pub const Config = struct {
    fonts: []const text.Font.FontKey = &.{.{ "default", @embedFile("fonts/default.ttf") }},
};

allocator: Allocator,
layout_ctx: layout.Context,
decorations: std.ArrayList(Decoration),
font: text.Font,
state: State,
input: Input,
hit_records: std.ArrayList(HitRecord),
hit_counter: u32,
content_scale: f32,
anim_active: bool,

const UI = @This();

pub fn init(allocator: Allocator, cfg: Config) !UI {
    return .{
        .allocator = allocator,
        .layout_ctx = .init(allocator),
        .decorations = .empty,
        .state = .init(allocator),
        .input = .{},
        .font = try .init(allocator, cfg.fonts),
        .hit_records = .empty,
        .hit_counter = 0,
        .content_scale = 1.0,
        .anim_active = false,
    };
}

pub fn beginFrame(self: *UI, window: *const Window) void {
    self.content_scale = window.getContentScale();
}

pub fn deinit(self: *UI) void {
    self.layout_ctx.deinit();
    self.decorations.deinit(self.allocator);
    self.font.deinit();
    self.state.deinit();
    self.hit_records.deinit(self.allocator);
}

pub fn open(self: *UI, key: Key, element: Element.Config, decoration: Decoration) !Element.Id {
    const id = key.hash();
    const slot = try self.layout_ctx.open(id, element);
    try self.decorations.append(self.allocator, decoration);
    if (decoration == .text) {
        const el = self.layout_ctx.pool.get(slot);
        el.intrinsic_w = decoration.text.intrinsic_w;
        el.intrinsic_h = decoration.text.intrinsic_h;
    }
    return id;
}

pub fn close(self: *UI) void {
    self.layout_ctx.close();
}

pub fn openRoot(self: *UI, key: Key, x: f32, y: f32, config: Element.Config, decoration: Decoration) !Element.Id {
    const id = key.hash();
    const slot = try self.layout_ctx.openRoot(id, config);
    try self.decorations.append(self.allocator, decoration);
    const el = self.layout_ctx.pool.get(slot);
    el.box.x = x;
    el.box.y = y;
    if (decoration == .text) {
        el.intrinsic_w = decoration.text.intrinsic_w;
        el.intrinsic_h = decoration.text.intrinsic_h;
    }
    return id;
}

pub fn lineHeight(self: *UI, size: f32, font: ?[]const u8) !f32 {
    const face = try self.font.getFace(font);
    const scale = self.content_scale;
    return (try face.lineHeight(size * scale)) / scale;
}

pub fn textDecoration(self: *UI, content: []const u8, size: f32, font: ?[]const u8) !Decoration {
    const face = try self.font.getFace(font);
    const scale = self.content_scale;
    const measured = try face.measure(content, size * scale);
    return .{ .text = .{
        .content = content,
        .size = size,
        .font = font,
        .intrinsic_w = measured.width / scale,
        .intrinsic_h = measured.height / scale,
    } };
}

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
    self.hit_records.clearRetainingCapacity();
    self.hit_counter = 0;
    self.anim_active = false;
}

/// Drive a time-based animation toward `target` for the given (element_id, channel)
/// pair. Returns the current eased value. On target change, snapshots the current
/// value as the new start_value so interrupted animations continue smoothly from
/// wherever they were rather than restarting.
///
/// Marks the UI dirty while in flight so the host app can keep ticking frames.
pub fn anim(self: *UI, element_id: Element.Id, channel: []const u8, target: f32, opts: AnimOpts) f32 {
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

    const elapsed: i64 = now - s.t0_ms;
    const raw_t: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(s.duration_ms));
    const t = std.math.clamp(raw_t, 0.0, 1.0);
    s.current = animation.lerp(s.start_value, s.target, s.ease.eval(t));
    if (t < 1.0) self.anim_active = true;
    return s.current;
}

pub fn resolve(self: *UI) !void {
    self.layout_ctx.computeSizes();
    self.layout_ctx.computeLayout(.{
        .ctx = @ptrCast(&self.state),
        .getFn = @ptrCast(&State.getScroll),
    });
    try self.layout_ctx.buildZOrder();
    self.syncStateBounds();
}

fn syncStateBounds(self: *UI) void {
    const root_box = self.layout_ctx.pool.get(self.layout_ctx.root_slot).box;
    for (self.layout_ctx.pool.elements.items) |el| {
        if (self.state.get(.text_select, el.id)) |s| s.box = el.box;
        if (self.state.get(.slider, el.id)) |s| s.bounds = el.box;
        if (self.state.get(.measured, el.id)) |s| {
            s.width = el.box.w;
            s.height = el.box.h;
        }
        if (el.z_index == 0) {
            if (self.state.get(.select_input, el.id)) |s| {
                s.anchor_box = el.box;
                s.viewport_box = root_box;
            }
        }
    }
}

pub fn hovering(self: *UI, id: Element.Id) bool {
    return self.state.hovered == id;
}

pub fn pressing(self: *UI, id: Element.Id) bool {
    return self.state.active == id;
}

pub fn clicked(self: *UI, id: Element.Id) bool {
    return self.input.mouse_pressed and self.state.active == id;
}

pub fn focused(self: *UI, id: Element.Id) bool {
    return self.state.focused == id;
}

pub fn isHoveredWithin(self: *UI, ancestor_id: Element.Id) bool {
    return self.isDescendantOrSelf(self.state.hovered, ancestor_id);
}

pub fn clickedWithin(self: *UI, ancestor_id: Element.Id) bool {
    if (!self.input.mouse_released) return false;
    if (self.state.press_drag) return false;
    if (!self.isDescendantOrSelf(self.state.press_origin, ancestor_id)) return false;
    return self.isDescendantOrSelf(self.state.hovered, ancestor_id);
}

fn isDescendantOrSelf(self: *UI, descendant_id: Element.Id, ancestor_id: Element.Id) bool {
    if (descendant_id == Element.INVALID_ID) return false;
    if (descendant_id == ancestor_id) return true;
    const ancestor_slot = self.layout_ctx.slotForId(ancestor_id) orelse return false;
    const descendant_slot = self.layout_ctx.slotForId(descendant_id) orelse return false;
    return self.layout_ctx.isDescendantOf(descendant_slot, ancestor_slot);
}

pub fn collectInput(self: *UI, input: Window.Input, now_ms: i64) !void {
    self.input.collect(input, now_ms);

    if (self.input.mouse_pressed) {
        self.state.active = self.state.hovered;
        self.state.focused = self.state.hovered;
        self.state.press_origin = self.state.hovered;
        self.state.press_pos = self.input.mouse_pos;
        self.state.press_drag = false;

        self.state.forEach(.text_select, self.state.hovered, clearOtherTextSelect);
    }
    if (self.input.mouse_down and !self.state.press_drag) {
        const dx = self.input.mouse_pos[0] - self.state.press_pos[0];
        const dy = self.input.mouse_pos[1] - self.state.press_pos[1];
        if (dx * dx + dy * dy > press_drag_threshold_sq) self.state.press_drag = true;
    }
    if (self.input.mouse_released) self.state.active = Element.INVALID_ID;

    if (self.layout_ctx.has_scroll and (input.scroll_delta[0] != 0 or input.scroll_delta[1] != 0)) {
        try self.routeScroll(self.layout_ctx.pool.elements.items, input);
    }

    self.state.endFrame();
}

const press_drag_threshold_sq: f64 = 9.0;

fn clearOtherTextSelect(hovered: Element.Id, id: Element.Id, s: *State.TextSelect) void {
    if (id == hovered) return;
    s.anchor_byte = 0;
    s.cursor_byte = 0;
    s.dragging = false;
}

pub fn resolveHit(self: *UI) void {
    const mx = self.input.mouse_pos[0];
    const my = self.input.mouse_pos[1];

    var best_id: Element.Id = Element.INVALID_ID;
    var best_layer: u8 = 0;
    var best_order: u32 = 0;

    for (self.hit_records.items) |rec| {
        const in_bounds = mx >= rec.bounds[0] and
            mx < rec.bounds[0] + rec.bounds[2] and
            my >= rec.bounds[1] and
            my < rec.bounds[1] + rec.bounds[3];
        if (!in_bounds) continue;

        if (rec.clip) |c| {
            const in_clip = mx >= c[0] and mx < c[0] + c[2] and
                my >= c[1] and my < c[1] + c[3];
            if (!in_clip) continue;
        }

        if (best_id == Element.INVALID_ID or
            rec.layer > best_layer or
            (rec.layer == best_layer and rec.insertion_order > best_order))
        {
            best_id = rec.id;
            best_layer = rec.layer;
            best_order = rec.insertion_order;
        }
    }

    self.state.hovered = best_id;
}

fn routeScroll(self: *UI, elements: []Element, input: Window.Input) !void {
    var j: Element.Slot = @intCast(elements.len);
    while (j > 0) {
        j -= 1;
        const el = self.layout_ctx.pool.get(j);
        if (!el.overflow.isScroll()) continue;
        const hit = self.input.mouse_pos[0] >= el.box.x and
            self.input.mouse_pos[0] < el.box.x + el.box.w and
            self.input.mouse_pos[1] >= el.box.y and
            self.input.mouse_pos[1] < el.box.y + el.box.h;
        if (hit) {
            const delta: [2]f32 = switch (el.overflow) {
                .scroll_x => .{ input.scroll_delta[0], 0 },
                .scroll_y => .{ 0, input.scroll_delta[1] },
                else => unreachable,
            };
            try self.state.addScroll(el.id, el, delta);
            return;
        }
    }
}

pub fn tessellate(self: *UI, allocator: Allocator, draw_list: *DrawList) !void {
    defer self.font.endFrame();
    var it = self.layout_ctx.z_used.iterator(.{});
    while (it.next()) |z| {
        draw_list.setLayer(@intCast(z));
        try self.tessellateLayer(allocator, draw_list, self.layout_ctx.zSlots(@intCast(z)), @intCast(z));
    }
    try draw_list.finalize();
    self.font.atlas.flush();
}

fn tessellateLayer(self: *UI, allocator: Allocator, draw_list: *DrawList, slots: []const Element.Slot, layer: u8) !void {
    const content_scale = self.content_scale;
    const elements = self.layout_ctx.pool.elements.items;

    var clip_rects: std.ArrayList([4]f32) = .empty;
    var clip_owners: std.ArrayList(Element.Slot) = .empty;

    for (slots) |slot| {
        const el = &elements[slot];

        while (clip_owners.items.len > 0) {
            if (self.layout_ctx.isDescendantOf(slot, clip_owners.items[clip_owners.items.len - 1])) break;
            _ = clip_owners.pop();
            _ = clip_rects.pop();
        }

        const clip: ?[4]f32 = if (clip_rects.items.len > 0) clip_rects.items[clip_rects.items.len - 1] else null;

        if (el.interactive) {
            try self.hit_records.append(self.allocator, .{
                .id = el.id,
                .bounds = .{ el.box.x, el.box.y, el.box.w, el.box.h },
                .clip = clip,
                .layer = layer,
                .insertion_order = self.hit_counter,
            });
            self.hit_counter += 1;
        }

        switch (self.decorations.items[slot]) {
            .none => {},
            .rect => |r| {
                if (clip) |c|
                    if (el.box.x >= c[0] + c[2] or
                        el.box.x + el.box.w <= c[0] or
                        el.box.y >= c[1] + c[3] or
                        el.box.y + el.box.h <= c[1])
                    {
                        if (el.overflow != .visible) {
                            const new_clip: [4]f32 = if (clip_rects.items.len > 0)
                                layout.Context.intersectClip(clip_rects.items[clip_rects.items.len - 1], .{ el.box.x, el.box.y, el.box.w, el.box.h })
                            else
                                .{ el.box.x, el.box.y, el.box.w, el.box.h };
                            try clip_rects.append(allocator, new_clip);
                            try clip_owners.append(allocator, slot);
                        }
                        continue;
                    };

                const inst = gpu.Instance{
                    .pos = .{ el.box.x, el.box.y },
                    .size = .{ el.box.w, el.box.h },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 0, 0 },
                    .color = r.color,
                    .border_color = r.border_color,
                    .corner_radius = r.corner_radius,
                    .border_width = r.border_width,
                    .prim_type = 0.0,
                };
                try draw_list.pushInstances(&[_]gpu.Instance{inst}, null, clip);
            },
            .text => |t| if (t.content.len > 0) {
                const face = try self.font.getFace(t.font);
                const shaped = try face.shape(t.content, t.size * content_scale);
                const glyphs = shaped.glyphs;
                if (glyphs.len > 0) {
                    const ascender = shaped.ascender / content_scale;
                    const baseline = el.box.y + ascender;
                    const zero4 = [4]f32{ 0, 0, 0, 0 };

                    const inst_buf = try allocator.alloc(gpu.Instance, glyphs.len);
                    var quad_count: u32 = 0;

                    for (glyphs) |gl| {
                        if (gl.metrics.rect.width == 0) continue;

                        const gx = el.box.x + gl.x / content_scale;
                        const gy = baseline - gl.metrics.bearing_y / content_scale;
                        const gw = gl.metrics.rect.width / content_scale;
                        const gh = gl.metrics.rect.height / content_scale;

                        if (clip) |c| {
                            if (gx >= c[0] + c[2] or
                                gx + gw <= c[0] or
                                gy >= c[1] + c[3] or
                                gy + gh <= c[1]) continue;
                        }

                        const u = gl.metrics.rect.u;
                        const v = gl.metrics.rect.v;
                        const uw = gl.metrics.rect.uw;
                        const uh = gl.metrics.rect.uh;

                        inst_buf[quad_count] = .{
                            .pos = .{ gx, gy },
                            .size = .{ gw, gh },
                            .uv0 = .{ u, v },
                            .uv1 = .{ u + uw, v + uh },
                            .color = t.color,
                            .border_color = zero4,
                            .corner_radius = 0,
                            .border_width = 0,
                            .prim_type = 1.0,
                        };
                        quad_count += 1;
                    }

                    if (quad_count > 0) {
                        try draw_list.pushInstances(inst_buf[0..quad_count], null, clip);
                    }
                }
            },
            .canvas => |c| {
                const ox = el.box.x;
                const oy = el.box.y;
                const zero4 = [4]f32{ 0, 0, 0, 0 };
                const flat_hs = [2]f32{ 1e4, 1e4 };

                for (c.cmds) |cmd| {
                    switch (cmd) {
                        .fill_rect => |fr| {
                            const inst = gpu.Instance{
                                .pos = .{ ox + fr.x, oy + fr.y },
                                .size = .{ fr.w, fr.h },
                                .uv0 = .{ 0, 0 },
                                .uv1 = .{ 0, 0 },
                                .color = fr.color,
                                .border_color = zero4,
                                .corner_radius = fr.corner_radius,
                                .border_width = 0,
                                .prim_type = 0.0,
                            };
                            try draw_list.pushInstances(&[_]gpu.Instance{inst}, null, clip);
                        },
                        .fill_rect_gradient => |fr| {
                            const hw = fr.w / 2.0;
                            const hh = fr.h / 2.0;
                            const fcx = ox + fr.x + hw;
                            const fcy = oy + fr.y + hh;
                            const vertices = [4]gpu.Vertex{
                                .{ .pos = .{ fcx - hw, fcy - hh }, .uv = .{ -hw, -hh }, .color = fr.colors[0], .corner_radius = fr.corner_radius, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ fcx + hw, fcy - hh }, .uv = .{ hw, -hh }, .color = fr.colors[1], .corner_radius = fr.corner_radius, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ fcx + hw, fcy + hh }, .uv = .{ hw, hh }, .color = fr.colors[2], .corner_radius = fr.corner_radius, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ fcx - hw, fcy + hh }, .uv = .{ -hw, hh }, .color = fr.colors[3], .corner_radius = fr.corner_radius, .half_size = .{ hw, hh }, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                            };
                            try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
                        },
                        .stroke_rect => |sr| {
                            const inst = gpu.Instance{
                                .pos = .{ ox + sr.x, oy + sr.y },
                                .size = .{ sr.w, sr.h },
                                .uv0 = .{ 0, 0 },
                                .uv1 = .{ 0, 0 },
                                .color = zero4,
                                .border_color = sr.color,
                                .corner_radius = sr.corner_radius,
                                .border_width = sr.thickness,
                                .prim_type = 0.0,
                            };
                            try draw_list.pushInstances(&[_]gpu.Instance{inst}, null, clip);
                        },
                        .fill_circle => |fc| {
                            const cr = fc.radius;
                            const inst = gpu.Instance{
                                .pos = .{ ox + fc.cx - cr, oy + fc.cy - cr },
                                .size = .{ cr * 2, cr * 2 },
                                .uv0 = .{ 0, 0 },
                                .uv1 = .{ 0, 0 },
                                .color = fc.color,
                                .border_color = zero4,
                                .corner_radius = cr,
                                .border_width = 0,
                                .prim_type = 0.0,
                            };
                            try draw_list.pushInstances(&[_]gpu.Instance{inst}, null, clip);
                        },
                        .stroke_circle => |sc| {
                            const cr = sc.radius;
                            const inst = gpu.Instance{
                                .pos = .{ ox + sc.cx - cr, oy + sc.cy - cr },
                                .size = .{ cr * 2, cr * 2 },
                                .uv0 = .{ 0, 0 },
                                .uv1 = .{ 0, 0 },
                                .color = zero4,
                                .border_color = sc.color,
                                .corner_radius = cr,
                                .border_width = sc.thickness,
                                .prim_type = 0.0,
                            };
                            try draw_list.pushInstances(&[_]gpu.Instance{inst}, null, clip);
                        },
                        .line => |l| {
                            const dx = l.to[0] - l.from[0];
                            const dy = l.to[1] - l.from[1];
                            const len = @sqrt(dx * dx + dy * dy);
                            if (len < 1e-6) continue;
                            const nx = -dy / len * l.thickness * 0.5;
                            const ny = dx / len * l.thickness * 0.5;
                            const x0 = ox + l.from[0];
                            const y0 = oy + l.from[1];
                            const x1 = ox + l.to[0];
                            const y1 = oy + l.to[1];
                            const zero2 = [2]f32{ 0, 0 };
                            const vertices = [4]gpu.Vertex{
                                .{ .pos = .{ x0 + nx, y0 + ny }, .uv = zero2, .color = l.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ x1 + nx, y1 + ny }, .uv = zero2, .color = l.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ x1 - nx, y1 - ny }, .uv = zero2, .color = l.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ x0 - nx, y0 - ny }, .uv = zero2, .color = l.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                            };
                            try draw_list.push(&vertices, &.{ 0, 1, 2, 0, 2, 3 }, null, clip);
                        },
                        .fill_triangle => |t| {
                            const zero2 = [2]f32{ 0, 0 };
                            const vertices = [3]gpu.Vertex{
                                .{ .pos = .{ ox + t.points[0][0], oy + t.points[0][1] }, .uv = zero2, .color = t.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ ox + t.points[1][0], oy + t.points[1][1] }, .uv = zero2, .color = t.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                                .{ .pos = .{ ox + t.points[2][0], oy + t.points[2][1] }, .uv = zero2, .color = t.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 },
                            };
                            try draw_list.push(&vertices, &.{ 0, 1, 2 }, null, clip);
                        },
                        .fill_convex_polygon => |p| {
                            if (p.points.len < 3) continue;
                            const zero2 = [2]f32{ 0, 0 };
                            const verts = try allocator.alloc(gpu.Vertex, p.points.len);
                            defer allocator.free(verts);
                            for (p.points, 0..) |pt, vi| {
                                verts[vi] = .{ .pos = .{ ox + pt[0], oy + pt[1] }, .uv = zero2, .color = p.color, .corner_radius = 0, .half_size = flat_hs, .border_width = 0, .border_color = zero4, .prim_type = 0.0 };
                            }
                            const n_tris = p.points.len - 2;
                            const fan_indices = try allocator.alloc(u32, n_tris * 3);
                            defer allocator.free(fan_indices);
                            for (0..n_tris) |i| {
                                fan_indices[i * 3] = 0;
                                fan_indices[i * 3 + 1] = @as(u32, @intCast(i)) + 1;
                                fan_indices[i * 3 + 2] = @as(u32, @intCast(i)) + 2;
                            }
                            try draw_list.push(verts, fan_indices, null, clip);
                        },
                    }
                }
            },
            .image => |img| {
                const zero4 = [4]f32{ 0, 0, 0, 0 };
                const inst = gpu.Instance{
                    .pos = .{ el.box.x, el.box.y },
                    .size = .{ el.box.w, el.box.h },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 1, 1 },
                    .color = img.tint,
                    .border_color = zero4,
                    .corner_radius = 0,
                    .border_width = 0,
                    .prim_type = 2.0,
                };
                try draw_list.pushInstances(&[_]gpu.Instance{inst}, img.texture_id, clip);
            },
            .slider => |s| {
                const bx = el.box.x;
                const by = el.box.y;
                const bw = el.box.w;
                const bh = el.box.h;
                const cr = s.corner_radius;
                const zero4 = [4]f32{ 0, 0, 0, 0 };

                const track = gpu.Instance{
                    .pos = .{ bx, by },
                    .size = .{ bw, bh },
                    .uv0 = .{ 0, 0 },
                    .uv1 = .{ 0, 0 },
                    .color = s.track_color,
                    .border_color = zero4,
                    .corner_radius = cr,
                    .border_width = 0,
                    .prim_type = 0.0,
                };
                try draw_list.pushInstances(&[_]gpu.Instance{track}, null, clip);

                if (s.progress > 0) {
                    const fill = gpu.Instance{
                        .pos = .{ bx, by },
                        .size = .{ bw * s.progress, bh },
                        .uv0 = .{ 0, 0 },
                        .uv1 = .{ 0, 0 },
                        .color = s.fill_color,
                        .border_color = zero4,
                        .corner_radius = cr,
                        .border_width = 0,
                        .prim_type = 0.0,
                    };
                    try draw_list.pushInstances(&[_]gpu.Instance{fill}, null, clip);
                }
            },
        }

        if (el.overflow != .visible) {
            const child_clip = [4]f32{ el.box.x, el.box.y, el.box.w, el.box.h };
            const new_clip: [4]f32 = if (clip_rects.items.len > 0)
                layout.Context.intersectClip(clip_rects.items[clip_rects.items.len - 1], child_clip)
            else
                child_clip;
            try clip_rects.append(allocator, new_clip);
            try clip_owners.append(allocator, slot);
        }
    }
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

    try ui.collectInput(.{
        .pos = .{ 150, 100 },
        .mouse_down_now = false,
        .scroll_delta = .{ 0, 50 },
        .chars = &.{},
        .keys = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0);
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
    var child_box: ?Element.Rect = null;
    for (ui.layout_ctx.pool.elements.items) |el| {
        if (el.id == child_id) {
            child_box = el.box;
            break;
        }
    }

    const box = child_box.?;
    try std.testing.expectApproxEqAbs(box.y, -50.0, 0.001);
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
