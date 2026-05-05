const std = @import("std");

const App = @import("knots").App;
const Key = @import("ui").Key;
const Element = @import("layout").Element;

pub const If = struct {
    when: bool,
    then: *const fn (*App) anyerror!void,
    @"else": ?*const fn (*App) anyerror!void = null,

    const Self = @This();

    pub fn eval(self: *const Self, app: *App) !void {
        if (self.when)
            try self.then(app)
        else if (self.@"else") |fb|
            try fb(app);
    }
};

pub fn For(comptime T: type) type {
    return struct {
        items: []const T,
        each: *const fn (*App, T, usize) anyerror!void,

        const Self = @This();

        pub fn eval(self: *const Self, app: *App) !void {
            for (self.items, 0..) |item, i| try self.each(app, item, i);
        }
    };
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
        each: *const fn (*App, T, usize) anyerror!void,
        overscan: u32 = 4,

        const Self = @This();

        pub fn eval(self: *const Self, app: *App) !void {
            const stack = app.ui.layout_ctx.stack.items;

            // Must be opened inside a parent.
            std.debug.assert(stack.len > 0);

            const parent_slot = stack[stack.len - 1];
            const parent_el = app.ui.layout_ctx.pool.get(parent_slot);
            const parent_id = parent_el.id;
            _ = try app.ui.state.getOrCreate(.measured, app.ui.allocator, parent_id);

            const measured_h: f32 = if (app.ui.state.get(.measured, parent_id)) |s| s.height else 0;
            const configured_h: f32 = if (parent_el.height.kind == .fixed) parent_el.height.value else 0;
            const parent_h: f32 = if (measured_h > 0) measured_h else configured_h;

            if (parent_h <= 0 or self.row_height <= 0) {
                for (self.items, 0..) |item, i| try self.each(app, item, i);
                return;
            }

            const scroll_y = app.ui.state.getScroll(parent_id)[1];
            const first_visible_f: f32 = @max(0, scroll_y / self.row_height);
            const visible_count_f: f32 = @ceil(parent_h / self.row_height) + 1;
            const first_visible: usize = @intFromFloat(first_visible_f);
            const visible_count: usize = @intFromFloat(visible_count_f);

            const first: usize = if (first_visible >= self.overscan)
                first_visible - self.overscan
            else
                0;

            const last: usize = @min(self.items.len, first_visible + visible_count + self.overscan);

            const lead_h = @as(f32, @floatFromInt(first)) * self.row_height;
            const trail_h = @as(f32, @floatFromInt(self.items.len - last)) * self.row_height;

            if (lead_h > 0) {
                _ = try app.ui.open(self.key.indexed(0), .{
                    .width = .grow(),
                    .height = .fixed(lead_h),
                }, .none);
                app.ui.close();
            }
            for (self.items[first..last], first..) |item, i| {
                try self.each(app, item, i);
            }
            if (trail_h > 0) {
                _ = try app.ui.open(self.key.indexed(1), .{
                    .width = .grow(),
                    .height = .fixed(trail_h),
                }, .none);
                app.ui.close();
            }
        }
    };
}
