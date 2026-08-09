const std = @import("std");

const Frame = @import("knots").Frame;
const Key = @import("ui").Key;
const Element = @import("layout").Element;

pub const If = struct {
    when: bool,
    then: *const fn (*Frame) anyerror!void,
    @"else": ?*const fn (*Frame) anyerror!void = null,

    const Self = @This();

    pub fn eval(self: *const Self, frame: *Frame) !void {
        if (self.when)
            try self.then(frame)
        else if (self.@"else") |fb|
            try fb(frame);
    }
};

pub fn For(comptime T: type) type {
    return struct {
        items: []const T,
        each: *const fn (*Frame, T, usize) anyerror!void,

        const Self = @This();

        pub fn eval(self: *const Self, frame: *Frame) !void {
            for (self.items, 0..) |item, i| try self.each(frame, item, i);
        }
    };
}

const VirtualRange = union(enum) {
    empty,
    placeholder: struct {
        total_h: f32,
    },
    visible: struct {
        first: usize,
        last: usize,
        lead_h: f32,
        trail_h: f32,
    },
};

fn virtualRange(item_count: usize, row_height: f32, viewport_h: f32, scroll_y: f32, overscan: u32) VirtualRange {
    if (item_count == 0 or row_height <= 0) return .empty;

    const total_h = @as(f32, @floatFromInt(item_count)) * row_height;
    if (viewport_h <= 0) return .{ .placeholder = .{ .total_h = total_h } };

    const max_first = item_count - 1;
    const first_visible_raw: usize = @intFromFloat(@max(0, scroll_y / row_height));
    const first_visible = @min(first_visible_raw, max_first);
    const visible_count: usize = @intFromFloat(@ceil(viewport_h / row_height) + 1);
    const overscan_usize: usize = overscan;

    const first = if (first_visible >= overscan_usize)
        first_visible - overscan_usize
    else
        0;
    const last = @min(item_count, first_visible + visible_count + overscan_usize);

    return .{ .visible = .{
        .first = first,
        .last = last,
        .lead_h = @as(f32, @floatFromInt(first)) * row_height,
        .trail_h = @as(f32, @floatFromInt(item_count - last)) * row_height,
    } };
}

/// Renders only the visible band of a long list. Must be the direct child
/// of a scroll container (the parent is read from the open stack), and the
/// rows must have a uniform `row_height`. Leading and trailing spacers
/// preserve scroll geometry so the scrollbar reflects the full content.
pub fn VirtualList(comptime T: type) type {
    return struct {
        key: Key,
        items: []const T,
        row_height: f32,
        each: *const fn (*Frame, T, usize) anyerror!void,
        overscan: u32 = 4,

        const Self = @This();

        pub fn eval(self: *const Self, frame: *Frame) !void {
            const stack = frame.ui().layout_ctx.stack.items;

            // Must be opened inside a parent.
            std.debug.assert(stack.len > 0);

            const parent_slot = stack[stack.len - 1];
            const parent_el = frame.ui().layout_ctx.pool.get(parent_slot);
            const parent_id = parent_el.id;
            _ = try frame.ui().state.getOrCreate(.measured, frame.ui().allocator, parent_id);

            const measured_h: f32 = if (frame.ui().state.get(.measured, parent_id)) |s| s.height else 0;
            const configured_h: f32 = if (parent_el.height.kind == .fixed) parent_el.height.value else 0;
            const parent_h: f32 = if (measured_h > 0) measured_h else configured_h;
            const scroll_y = frame.ui().state.getScroll(parent_id)[1];

            switch (virtualRange(self.items.len, self.row_height, parent_h, scroll_y, self.overscan)) {
                .empty => return,
                .placeholder => |r| {
                    if (r.total_h > 0) {
                        _ = try frame.ui().open(self.key.indexed(0), .{
                            .width = .grow(),
                            .height = .fixed(r.total_h),
                        }, .none);
                        frame.ui().close();
                        frame.requestRedraw();
                    }
                },
                .visible => |r| {
                    if (r.lead_h > 0) {
                        _ = try frame.ui().open(self.key.indexed(0), .{
                            .width = .grow(),
                            .height = .fixed(r.lead_h),
                        }, .none);
                        frame.ui().close();
                    }
                    for (self.items[r.first..r.last], r.first..) |item, i| {
                        try self.each(frame, item, i);
                    }
                    if (r.trail_h > 0) {
                        _ = try frame.ui().open(self.key.indexed(1), .{
                            .width = .grow(),
                            .height = .fixed(r.trail_h),
                        }, .none);
                        frame.ui().close();
                    }
                },
            }
        }
    };
}

test "virtual range uses placeholder when viewport is unknown" {
    const r = virtualRange(100, 10, 0, 0, 4);
    try std.testing.expectEqual(@as(std.meta.Tag(VirtualRange), .placeholder), r);
    try std.testing.expectApproxEqAbs(1000, r.placeholder.total_h, 0.001);
}

test "virtual range returns empty for empty lists" {
    const r = virtualRange(0, 10, 100, 0, 4);
    try std.testing.expectEqual(@as(std.meta.Tag(VirtualRange), .empty), r);
}

test "virtual range includes overscan and spacers" {
    const r = virtualRange(100, 10, 50, 200, 2).visible;
    try std.testing.expectEqual(@as(usize, 18), r.first);
    try std.testing.expectEqual(@as(usize, 28), r.last);
    try std.testing.expectApproxEqAbs(180, r.lead_h, 0.001);
    try std.testing.expectApproxEqAbs(720, r.trail_h, 0.001);
}

test "virtual range clamps large scroll offsets" {
    const r = virtualRange(100, 10, 50, 10_000, 2).visible;
    try std.testing.expectEqual(@as(usize, 97), r.first);
    try std.testing.expectEqual(@as(usize, 100), r.last);
    try std.testing.expectApproxEqAbs(970, r.lead_h, 0.001);
    try std.testing.expectApproxEqAbs(0, r.trail_h, 0.001);
}
