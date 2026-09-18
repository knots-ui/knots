//! Panel input routing and packet placement, shared by all execution modes.
const std = @import("std");
const input = @import("input");
const math = @import("math");

pub const Rect = math.Rect;
pub const panels_max = 32;

pub const Router = struct {
    focused: ?usize = null,
    captured: ?usize = null,
    hovered: ?usize = null,

    pub fn begin(self: *Router, rectangles: []const Rect, event: *const input.Input) !void {
        if (rectangles.len > panels_max) return error.TooManyPanels;
        self.hovered = null;
        for (rectangles, 0..) |rect, index| {
            for (@as([4]f32, rect.v)) |value| if (!std.math.isFinite(value)) return error.InvalidPanel;
            if (rect.w() < 0) return error.InvalidPanel;
            if (rect.h() < 0) return error.InvalidPanel;
            if (rect.isEmpty()) {
                self.replaced(index);
                continue;
            }
            if (rect.w() > 65535) return error.InvalidPanel;
            if (rect.h() > 65535) return error.InvalidPanel;
            for (rectangles[0..index]) |previous| {
                if (!rect.intersect(previous).isEmpty()) return error.OverlappingPanels;
            }
            if (event.pos[0] >= rect.x()) {
                if (event.pos[0] < rect.x() + rect.w()) {
                    if (event.pos[1] >= rect.y()) {
                        if (event.pos[1] < rect.y() + rect.h()) self.hovered = index;
                    }
                }
            }
        }
        if (!event.focused) {
            self.focused = null;
            self.captured = null;
        } else {
            for (event.mouse) |button| {
                if (button.pressed) {
                    self.focused = self.hovered;
                    if (self.captured == null) self.captured = self.hovered;
                }
            }
        }
        if (self.focused) |index| {
            if (index >= rectangles.len) self.focused = null;
        }
        if (self.captured) |index| {
            if (index >= rectangles.len) self.captured = null;
        }
    }

    pub fn route(self: *const Router, index: usize, rect: Rect, source: *const input.FrameInput) input.FrameInput {
        std.debug.assert(index < panels_max);
        std.debug.assert(rect.w() > 0);
        var result = source.*;
        result.logical_extent = .{ .width = @intFromFloat(rect.w()), .height = @intFromFloat(rect.h()) };
        result.physical_extent = .{ .width = @intFromFloat(@max(1, rect.w() * source.content_scale)), .height = @intFromFloat(@max(1, rect.h() * source.content_scale)) };
        result.input.pos[0] -= rect.x();
        result.input.pos[1] -= rect.y();
        const pointer_owner = self.captured orelse self.hovered;
        if (pointer_owner != index) {
            result.input.pos = .{ -1_000_000, -1_000_000 };
            result.input.mouse = @splat(.{});
            result.input.scroll = .{};
            result.dropped_paths = &.{};
        } else {
            for (&result.input.mouse) |*button| {
                if (button.pressed_pos) |*position| {
                    position[0] -= rect.x();
                    position[1] -= rect.y();
                }
                if (button.released_pos) |*position| {
                    position[0] -= rect.x();
                    position[1] -= rect.y();
                }
            }
        }
        result.input.focused = self.focused == index;
        if (self.focused != index) {
            result.input.chars = &.{};
            result.input.key_events = &.{};
            result.input.key_down = &input.no_keys_down;
            result.input.shift_held = false;
            result.input.ctrl_held = false;
            result.input.alt_held = false;
            result.input.super_held = false;
            result.paste_text = null;
        }
        return result;
    }

    pub fn finish(self: *Router, event: *const input.Input) void {
        for (event.mouse) |button| if (button.down) return;
        self.captured = null;
    }

    pub fn replaced(self: *Router, index: usize) void {
        std.debug.assert(index < panels_max);
        if (self.focused == index) self.focused = null;
        if (self.captured == index) self.captured = null;
    }
};

test "pointer capture, keyboard ownership, and collapsed regions" {
    const rectangles = [_]Rect{ .init(10, 20, 100, 100), .init(120, 20, 100, 100) };
    var router: Router = .{};
    var event: input.Input = .{ .pos = .{ 30, 40 } };
    event.mouse[0] = .{ .down = true, .pressed = true, .pressed_pos = .{ 30, 40 } };
    try router.begin(&rectangles, &event);
    const source: input.FrameInput = .{
        .input = event,
        .now_ms = 0,
        .delta_ns = 0,
        .logical_extent = .{ .width = 240, .height = 140 },
        .physical_extent = .{ .width = 480, .height = 280 },
        .content_scale = 2,
        .paste_text = "paste",
        .dropped_paths = &.{"file.txt"},
    };
    const active = router.route(0, rectangles[0], &source);
    const inactive = router.route(1, rectangles[1], &source);
    try std.testing.expectEqual([2]f64{ 20, 20 }, active.input.pos);
    try std.testing.expectEqual(@as(u32, 200), active.physical_extent.width);
    try std.testing.expectEqualStrings("paste", active.paste_text.?);
    try std.testing.expectEqual(@as(?[]const u8, null), inactive.paste_text);
    try std.testing.expectEqual(@as(usize, 0), inactive.dropped_paths.len);
    try std.testing.expect(!inactive.input.mouse[0].down);
    event.pos = .{ 150, 40 };
    event.mouse[0].pressed = false;
    try router.begin(&rectangles, &event);
    try std.testing.expectEqual(@as(?usize, 0), router.captured);
    try std.testing.expectEqual(@as(?usize, 1), router.hovered);
    const collapsed = [_]Rect{ .init(10, 20, 0, 0), rectangles[1] };
    try router.begin(&collapsed, &event);
    try std.testing.expectEqual(@as(?usize, null), router.captured);
    try std.testing.expectEqual(@as(?usize, null), router.focused);
    try std.testing.expectError(error.OverlappingPanels, router.begin(&.{ rectangles[0], rectangles[0] }, &event));
}
