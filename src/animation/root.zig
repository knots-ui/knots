const std = @import("std");

const knots = @import("knots");
const Element = @import("layout").Element;

const App = knots.App;
const ui = knots.ui;

// This is pretty stupid, but I am too lazy to think of a better way of preventing key collosions.
const COLLAPSIBLE_KEY_SALT: usize = 0x4001;

pub const Collapsible = struct {
    key: ui.Key,
    open: bool,
    animation: ui.animation.Options = .{
        .duration_ms = 250,
        .ease = .ease_out_cubic,
    },
    width: Element.sizing.Axis = .grow(),
    child: *const fn (*App) anyerror!void,

    pub fn eval(self: *const Collapsible, app: *App) !void {
        const measure_key = self.key.indexed(COLLAPSIBLE_KEY_SALT + 0);
        const tween_key = self.key.indexed(COLLAPSIBLE_KEY_SALT + 1);
        const clip_key = self.key.indexed(COLLAPSIBLE_KEY_SALT + 2);
        const measure_id = measure_key.hash();

        _ = try app.ui.state.getOrCreate(.measured, app.ui.allocator, measure_id);
        const measured_h: f32 = if (app.ui.state.get(.measured, measure_id)) |s| s.height else 0;
        const target_h: f32 = if (self.open) measured_h else 0;
        const h = app.ui.anim(tween_key.hash(), "h", target_h, self.animation);

        if (!self.open and h <= 0) return;

        const need_remeasure = self.open and measured_h == 0;
        const clip_height: Element.sizing.Axis =
            if (need_remeasure) .fit() else .fixed(h);

        _ = try app.ui.open(clip_key, .{
            .width = self.width,
            .height = clip_height,
            .direction = .column,
            .overflow = .hidden,
        }, .none);
        defer app.ui.close();

        _ = try app.ui.open(measure_key, .{
            .width = self.width,
            .height = .fit(),
        }, .none);
        defer app.ui.close();
        try self.child(app);
    }
};
