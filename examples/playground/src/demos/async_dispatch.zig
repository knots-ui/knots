const std = @import("std");
const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;

pub fn render(desktop: *knots.App, app: *knots.Frame) !void {
    try ui_helpers.panel(desktop, app, "Async dispatch", body);
}

fn body(desktop: *knots.App, app: *knots.Frame) !void {
    const self = Self.of(desktop);
    const arena = app.arena();

    const row = Rect{ .width = .grow(), .dir = .row, .gap = 12, .@"align" = .center, .key = .src(@src()) };
    _ = try row.open(app);
    if ((try app.interact(Button{
        .key = .src(@src()),
        .width = .fixed(140),
        .height = .fixed(34),
        .style = .{ .color = .primary, .corner_radius = .sm },
        .hover_anim = .{},
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "sleep x10" },
    })).clicked) try sleep10(self, app);
    try app.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "pending: {d}", .{self.demo_state.pending_async}),
            .size = .sm,
            .color = if (self.demo_state.pending_async > 0) .warning else .dimmed,
            .key = .src(@src()),
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "wakeups received: {d}", .{self.demo_state.counter}),
            .size = .sm,
            .color = .dimmed,
            .key = .src(@src()),
        },
    });
    try row.close(app);

    try app.e(Spacer{ .height = .fixed(16), .key = .src(@src()) });

    try app.e(Text{
        .content = "each task sleeps 0..10 seconds. Wakeups land back on the main loop without blocking the UI.",
        .size = .xs,
        .color = .dimmed,
        .key = .src(@src()),
    });
}

fn sleep10(self: *Self, app: *knots.Frame) !void {
    for (1..11) |i| {
        self.app.dispatch(
            doSleep,
            .{ self.io, @as(i64, @intCast(i)) },
            onWakeup,
        ) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                std.log.warn("async dispatch is unavailable because this build has no thread support", .{});
                if (self.demo_state.pending_async > 0) app.requestRedraw();
                return;
            },
            else => return err,
        };
        self.demo_state.pending_async += 1;
    }
    app.requestRedraw();
}

fn doSleep(io: std.Io, seconds: i64) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(seconds), .boot);
}

fn onWakeup(desktop: *knots.App, app: *knots.Frame, _: std.Io.Cancelable!void) !void {
    const self = Self.of(desktop);
    self.demo_state.counter += 1;
    if (self.demo_state.pending_async > 0) self.demo_state.pending_async -= 1;
    app.requestRedraw();
}
