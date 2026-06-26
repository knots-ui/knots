const std = @import("std");
const math = @import("math");
const layout = @import("layout");
const gpu = @import("gpu");
const window = @import("window");
const DrawList = @import("render").DrawList;
const Clip = @import("render").Clip;

const Element = layout.Element;
const State = @import("State.zig");
const Theme = @import("Theme.zig");
const UI = @import("UI.zig");
const BorderWidth = @import("BorderWidth.zig");

const THUMB_ID_SALT: Element.Id = 0x5C205C205C205C20;
const WHEEL_LOCK_IDLE_MS: i64 = 120;
const WHEEL_LOCK_MIN_DELTA: f32 = 0.005;

pub const Geom = struct {
    bars: [2]?Bar = .{ null, null },

    const Bar = struct {
        track: math.Rect,
        thumb: math.Rect,
        axis: State.Scroll.Axis,
    };
};

pub const SlotGeom = struct {
    slot: Element.Slot,
    layer: u8 = 0,
    parent_clip: Clip.State = .{},
    geom: Geom,
};

fn idFor(container_id: Element.Id) Element.Id {
    return container_id ^ THUMB_ID_SALT;
}

fn thumbLen(track_len: f32, ratio: f32, min_thumb: f32) f32 {
    return @min(track_len, @max(min_thumb, track_len * ratio));
}

fn axisHasRange(axis: State.Scroll.Axis, max_offset: math.Vec2) bool {
    return switch (axis) {
        .x => max_offset[0] > 0,
        .y => max_offset[1] > 0,
        .none => false,
    };
}

fn axisDelta(axis: State.Scroll.Axis, delta: math.Vec2) f32 {
    return switch (axis) {
        .x => delta[0],
        .y => delta[1],
        .none => 0,
    };
}

fn otherAxis(axis: State.Scroll.Axis) State.Scroll.Axis {
    return switch (axis) {
        .x => .y,
        .y => .x,
        .none => .none,
    };
}

fn chooseWheelAxis(delta: math.Vec2, max_offset: math.Vec2) State.Scroll.Axis {
    const abs_x = @abs(delta[0]);
    const abs_y = @abs(delta[1]);
    if (abs_x <= WHEEL_LOCK_MIN_DELTA and abs_y <= WHEEL_LOCK_MIN_DELTA) return .none;

    const primary: State.Scroll.Axis = if (abs_x > abs_y) .x else .y;
    if (axisHasRange(primary, max_offset)) return primary;

    const fallback = otherAxis(primary);
    if (@abs(axisDelta(fallback, delta)) > WHEEL_LOCK_MIN_DELTA and axisHasRange(fallback, max_offset))
        return fallback;

    return .none;
}

fn lockedWheelDelta(ui: *UI, el: *const Element, delta: math.Vec2) !math.Vec2 {
    const s = try ui.state.getOrCreate(.scroll, ui.allocator, el.id);
    const metrics = Element.scrollMetrics(el.overflow, el.box, el.content_w, el.content_h, ui.theme.scrollbar_thickness);
    const now = ui.input.now_ms;

    if (now - s.wheel_last_ms > WHEEL_LOCK_IDLE_MS)
        s.wheel_axis = .none;

    if (s.wheel_axis == .none or !axisHasRange(s.wheel_axis, metrics.max_offset))
        s.wheel_axis = chooseWheelAxis(delta, metrics.max_offset);

    if (@abs(delta[0]) > WHEEL_LOCK_MIN_DELTA or @abs(delta[1]) > WHEEL_LOCK_MIN_DELTA)
        s.wheel_last_ms = now;

    return switch (s.wheel_axis) {
        .x => .{ delta[0], 0 },
        .y => .{ 0, delta[1] },
        .none => .{ 0, 0 },
    };
}

fn resolveScrollInput(ui: *UI, el: *const Element) !math.Vec2 {
    const input = ui.input.scroll;
    const has_line_or_page = input.line[0] != 0 or input.line[1] != 0 or
        input.page[0] != 0 or input.page[1] != 0;
    const line_h = if (has_line_or_page) try ui.scrollLineHeight() else 0;
    const metrics = Element.scrollMetrics(el.overflow, el.box, el.content_w, el.content_h, ui.theme.scrollbar_thickness);
    const page_x = @max(0, metrics.viewport_w - line_h);
    const page_y = @max(0, metrics.viewport_h - line_h);

    return .{
        input.pixel[0] + input.line[0] * line_h + input.page[0] * page_x,
        input.pixel[1] + input.line[1] * line_h + input.page[1] * page_y,
    };
}

pub fn compute(el: *const Element, offset: math.Vec2, theme: *const Theme) ?Geom {
    const thickness = theme.scrollbar_thickness;
    const min_thumb = theme.scrollbar_min_thumb;
    const box_w = el.box.w();
    const box_h = el.box.h();

    const metrics = Element.scrollMetrics(el.overflow, el.box, el.content_w, el.content_h, thickness);
    if (!metrics.has_x and !metrics.has_y) return null;

    var x_geom: ?Geom.Bar = null;
    var y_geom: ?Geom.Bar = null;

    if (metrics.has_x) {
        const track_w = metrics.viewport_w;
        const track_x = el.box.x();
        const track_y = el.box.y() + box_h - thickness;
        const ratio = std.math.clamp(metrics.viewport_w / el.content_w, 0, 1);
        const thumb_w = thumbLen(track_w, ratio, min_thumb);
        const free = @max(0, track_w - thumb_w);
        const max_off = metrics.max_offset[0];
        const t = if (max_off > 0) std.math.clamp(offset[0] / max_off, 0, 1) else 0;
        const thumb_x = track_x + free * t;
        x_geom = .{
            .track = math.Rect.init(track_x, track_y, track_w, thickness),
            .thumb = math.Rect.init(thumb_x, track_y, thumb_w, thickness),
            .axis = .x,
        };
    }

    if (metrics.has_y) {
        const track_h = metrics.viewport_h;
        const track_x = el.box.x() + box_w - thickness;
        const track_y = el.box.y();
        const ratio = std.math.clamp(metrics.viewport_h / el.content_h, 0, 1);
        const thumb_h = thumbLen(track_h, ratio, min_thumb);
        const free = @max(0, track_h - thumb_h);
        const max_off = metrics.max_offset[1];
        const t = if (max_off > 0) std.math.clamp(offset[1] / max_off, 0, 1) else 0;
        const thumb_y = track_y + free * t;
        y_geom = .{
            .track = math.Rect.init(track_x, track_y, thickness, track_h),
            .thumb = math.Rect.init(track_x, thumb_y, thickness, thumb_h),
            .axis = .y,
        };
    }

    return Geom{ .bars = .{ x_geom, y_geom } };
}

pub fn route(ui: *UI) !void {
    const elements = ui.layout_ctx.pool.elements.items;
    const p: math.Vec2 = .{ @floatCast(ui.input.mouse_pos[0]), @floatCast(ui.input.mouse_pos[1]) };
    const has_wheel = !ui.input.scroll.isZero();

    var wheel_target: ?struct { slot: Element.Slot } = null;
    var press_target: ?struct { slot: Element.Slot, bar: Geom.Bar } = null;

    for (ui.layout_ctx.scroll_slots.items) |slot| {
        const el = &elements[slot];
        if (!ui.acceptsInput(el.id)) continue;
        _ = ui.state.clampScroll(el.id, el, ui.theme.scrollbar_thickness);
        const offset = ui.state.getScroll(el.id);
        const geom = compute(el, .{ offset[0], offset[1] }, &ui.theme) orelse continue;

        if (has_wheel and el.box.contains(p)) wheel_target = .{ .slot = slot };

        for (geom.bars) |maybe_bar| {
            const bar = maybe_bar orelse continue;
            if (ui.input.mouseButton(.left).pressed and bar.thumb.contains(p))
                press_target = .{ .slot = slot, .bar = bar };
        }

        const s = ui.state.get(.scroll, el.id) orelse continue;
        if (s.drag_axis == .none) continue;

        if (!ui.input.mouseButton(.left).down) {
            s.drag_axis = .none;
            continue;
        }

        const active_bar: Geom.Bar = blk: {
            for (geom.bars) |maybe_bar| {
                const bar = maybe_bar orelse continue;
                if (bar.axis == s.drag_axis) break :blk bar;
            }
            s.drag_axis = .none;
            continue;
        };

        switch (active_bar.axis) {
            .y => {
                const my: f32 = @floatCast(ui.input.mouse_pos[1]);
                const free = @max(0, active_bar.track.h() - active_bar.thumb.h());
                const max_off = Element.scrollMetrics(el.overflow, el.box, el.content_w, el.content_h, ui.theme.scrollbar_thickness).max_offset[1];
                if (free <= 0 or max_off <= 0) continue;
                const t = std.math.clamp((my - s.drag_grab - active_bar.track.y()) / free, 0, 1);
                s.offset = .{ s.offset[0], t * max_off };
            },
            .x => {
                const mx: f32 = @floatCast(ui.input.mouse_pos[0]);
                const free = @max(0, active_bar.track.w() - active_bar.thumb.w());
                const max_off = Element.scrollMetrics(el.overflow, el.box, el.content_w, el.content_h, ui.theme.scrollbar_thickness).max_offset[0];
                if (free <= 0 or max_off <= 0) continue;
                const t = std.math.clamp((mx - s.drag_grab - active_bar.track.x()) / free, 0, 1);
                s.offset = .{ t * max_off, s.offset[1] };
            },
            .none => unreachable,
        }
    }

    if (wheel_target) |w| {
        const el = &elements[w.slot];
        const resolved = try resolveScrollInput(ui, el);
        const delta: math.Vec2 = switch (el.overflow) {
            .scroll_x => .{ resolved[0], 0 },
            .scroll_y => .{ 0, resolved[1] },
            .scroll => try lockedWheelDelta(ui, el, resolved),
            else => unreachable,
        };
        ui.input.scroll_delta = delta;
        try ui.state.addScroll(el.id, el, delta, ui.theme.scrollbar_thickness);
    }

    if (press_target) |pt| {
        const el = &elements[pt.slot];
        const s = try ui.state.getOrCreate(.scroll, ui.allocator, el.id);
        s.drag_axis = pt.bar.axis;
        s.drag_grab = switch (pt.bar.axis) {
            .y => @as(f32, @floatCast(ui.input.mouse_pos[1])) - pt.bar.thumb.y(),
            .x => @as(f32, @floatCast(ui.input.mouse_pos[0])) - pt.bar.thumb.x(),
            .none => 0,
        };
    }
}

pub fn recordForTessellate(ui: *UI, slot: Element.Slot, parent_clip: Clip.State, layer: u8) !void {
    const el = &ui.layout_ctx.pool.elements.items[slot];
    const offset = ui.state.getScroll(el.id);
    const geom = compute(el, .{ offset[0], offset[1] }, &ui.theme) orelse return;
    try ui.scroll_geoms.append(ui.allocator, .{
        .slot = slot,
        .layer = layer,
        .parent_clip = parent_clip,
        .geom = geom,
    });
}

pub fn render(ui: *UI, draw_list: *DrawList, layer: u8) !void {
    const elements = ui.layout_ctx.pool.elements.items;
    const cr = ui.theme.scrollbar_corner_radius.value;
    const base: math.Vec4 = ui.theme.scrollbar_thumb_color.value;
    const hi: math.Vec4 = ui.theme.scrollbar_thumb_hover_color.value;
    const track_color: [4]f32 = ui.theme.scrollbar_track_color.value;

    for (ui.scroll_geoms.items) |sg| {
        if (sg.layer != layer) continue;
        const el = &elements[sg.slot];
        const sb_id = idFor(el.id);

        for (sg.geom.bars) |maybe_bar| {
            const bar = maybe_bar orelse continue;

            const track_inst = gpu.Instance{
                .pos = .{ bar.track.x(), bar.track.y() },
                .size = .{ bar.track.w(), bar.track.h() },
                .uv0 = .{ 0, 0 },
                .uv1 = .{ 0, 0 },
                .color = track_color,
                .border_color = .{ 0, 0, 0, 0 },
                .corner_radius = cr,
                .border_width = BorderWidth.zero.value,
                .prim_type = 0.0,
            };
            try draw_list.pushInstances(&[_]gpu.Instance{track_inst}, null, sg.parent_clip);

            const dragging = if (ui.state.get(.scroll, el.id)) |s| s.drag_axis == bar.axis else false;
            const hovered = ui.state.hovered == sb_id or dragging;
            const hover_t = ui.anim(sb_id, "sb_hover", if (hovered) 1.0 else 0.0, .{ .duration_ms = 100 });
            const thumb_color: [4]f32 = math.lerp(base, hi, hover_t);

            const thumb_inst = gpu.Instance{
                .pos = .{ bar.thumb.x(), bar.thumb.y() },
                .size = .{ bar.thumb.w(), bar.thumb.h() },
                .uv0 = .{ 0, 0 },
                .uv1 = .{ 0, 0 },
                .color = thumb_color,
                .border_color = .{ 0, 0, 0, 0 },
                .corner_radius = cr,
                .border_width = BorderWidth.zero.value,
                .prim_type = 0.0,
            };
            try draw_list.pushInstances(&[_]gpu.Instance{thumb_inst}, null, sg.parent_clip);

            try ui.appendHitWithScope(sb_id, bar.thumb, sg.parent_clip, layer, el.input_scope);
        }

        // Corner fill when both bars are present.
        if (sg.geom.bars[0] != null and sg.geom.bars[1] != null) {
            const thickness = ui.theme.scrollbar_thickness;
            const corner_inst = gpu.Instance{
                .pos = .{ el.box.x() + el.box.w() - thickness, el.box.y() + el.box.h() - thickness },
                .size = .{ thickness, thickness },
                .uv0 = .{ 0, 0 },
                .uv1 = .{ 0, 0 },
                .color = track_color,
                .border_color = .{ 0, 0, 0, 0 },
                .corner_radius = .{ 0, 0, 0, 0 },
                .border_width = BorderWidth.zero.value,
                .prim_type = 0.0,
            };
            try draw_list.pushInstances(&[_]gpu.Instance{corner_inst}, null, sg.parent_clip);
        }
    }
}

const Key = @import("Key.zig");
const testing = std.testing;

fn testScrollElement(overflow: Element.Overflow, box_w: f32, box_h: f32, content_w: f32, content_h: f32) Element {
    var el = (Element.Config{
        .width = .fixed(box_w),
        .height = .fixed(box_h),
        .overflow = overflow,
    }).toElement();
    el.box = math.Rect.init(0, 0, box_w, box_h);
    el.content_w = content_w;
    el.content_h = content_h;
    return el;
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

fn wheelInput(delta: math.Vec2) window.Input {
    return .{
        .pos = .{ 50, 50 },
        .scroll = .{ .pixel = delta },
        .chars = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    };
}

fn scrollInput(scroll: window.ScrollInput) window.Input {
    return .{
        .pos = .{ 50, 50 },
        .scroll = scroll,
        .chars = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    };
}

test "scroll overflow only renders axes that independently overflow" {
    const vertical_only = testScrollElement(.scroll, 100, 100, 96, 120);
    const vh_metrics = Element.scrollMetrics(
        vertical_only.overflow,
        vertical_only.box,
        vertical_only.content_w,
        vertical_only.content_h,
        8,
    );
    try testing.expect(!vh_metrics.has_x);
    try testing.expect(vh_metrics.has_y);
    try testing.expectApproxEqAbs(0, vh_metrics.max_offset[0], 0.001);
    try testing.expectApproxEqAbs(20, vh_metrics.max_offset[1], 0.001);

    const both_axes = testScrollElement(.scroll, 100, 80, 200, 300);
    const both_metrics = Element.scrollMetrics(both_axes.overflow, both_axes.box, both_axes.content_w, both_axes.content_h, 8);
    try testing.expect(both_metrics.has_x);
    try testing.expect(both_metrics.has_y);
    try testing.expectApproxEqAbs(108, both_metrics.max_offset[0], 0.001);
    try testing.expectApproxEqAbs(228, both_metrics.max_offset[1], 0.001);
}

test "two axis wheel scroll locks one axis per gesture" {
    const allocator = testing.allocator;
    var ui = try UI.init(allocator, .{});
    defer ui.deinit();

    try buildTwoAxisScrollTree(&ui);
    try ui.resolve();

    try ui.resolveWindow(wheelInput(.{ 40, 5 }), 0, 0);
    try ui.resolveWindow(wheelInput(.{ 2, 50 }), WHEEL_LOCK_IDLE_MS - 1, 0);

    const s = ui.state.get(.scroll, Key.str("root").hash()).?;
    try testing.expectEqual(State.Scroll.Axis.x, s.wheel_axis);
    try testing.expectApproxEqAbs(42, s.offset[0], 0.001);
    try testing.expectApproxEqAbs(0, s.offset[1], 0.001);
    try ui.resolveWindow(wheelInput(.{ 2, 50 }), WHEEL_LOCK_IDLE_MS * 2, 0);

    try testing.expectEqual(State.Scroll.Axis.y, s.wheel_axis);
    try testing.expectApproxEqAbs(42, s.offset[0], 0.001);
    try testing.expectApproxEqAbs(50, s.offset[1], 0.001);
}

test "pixel wheel scroll is independent of content scale" {
    const allocator = testing.allocator;

    var ui1 = try UI.init(allocator, .{});
    defer ui1.deinit();
    try buildScrollYTree(&ui1);
    try ui1.resolve();
    try ui1.resolveWindow(wheelInput(.{ 0, 25 }), 0, 1);

    var ui2 = try UI.init(allocator, .{});
    defer ui2.deinit();
    try buildScrollYTree(&ui2);
    try ui2.resolve();
    try ui2.resolveWindow(wheelInput(.{ 0, 25 }), 0, 2);

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
    try ui.resolve();

    const root_id = root_key.hash();
    var root_el: ?*const Element = null;
    for (ui.layout_ctx.pool.elements.items) |*el| {
        if (el.id == root_id) {
            root_el = el;
            break;
        }
    }

    const geom = compute(root_el.?, .{ 0, 0 }, &ui.theme).?;
    const bar = geom.bars[1].?;
    const thumb_top_y = bar.thumb.y();

    try ui.resolveWindow(.{
        .pos = .{ bar.thumb.x() + 1, thumb_top_y + 4 },
        .mouse = blk: {
            var buttons: [window.mouse_button_count]window.MouseButtonState = @splat(.{});
            buttons[@intFromEnum(window.MouseButton.left)].down = true;
            break :blk buttons;
        },
        .scroll = .{},
        .chars = &.{},
        .shift_held = false,
        .ctrl_held = false,
        .super_held = false,
    }, 0, 0);
    ui.reset();
    try buildTree(&ui);
    try ui.resolve();

    const s_after_press = ui.state.get(.scroll, root_id).?;
    try testing.expectEqual(State.Scroll.Axis.y, s_after_press.drag_axis);
    try testing.expectApproxEqAbs(4, s_after_press.drag_grab, 0.001);

    const drag_target_y = thumb_top_y + 30;
    try ui.resolveWindow(.{
        .pos = .{ bar.thumb.x() + 1, drag_target_y },
        .mouse = blk: {
            var buttons: [window.mouse_button_count]window.MouseButtonState = @splat(.{});
            buttons[@intFromEnum(window.MouseButton.left)].down = true;
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

    try ui.resolveWindow(.{
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
    try ui.resolve();

    try ui.resolveWindow(.{
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
