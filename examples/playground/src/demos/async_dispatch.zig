const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const Playground = @import("../Playground.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Spacer = ui.component.Spacer;

pending: usize = 0,
wakeups: usize = 0,

pub fn render(self: *@This(), app: *knots.App, frame: *ui.Frame) !void {
    const arena = frame.arena();

    const row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 12, .@"align" = .center } };
    _ = try row.open(frame);
    if ((try frame.interact(Button{
        .key = .src(@src()),
        .label = "sleep x10",
        .style = &.{ .width = .fixed(140), .height = .fixed(34) },
    })).clicked) try self.sleep10(app, frame);
    try frame.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "pending: {d}", .{self.pending}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = if (self.pending > 0) .warning else .dimmed },
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "wakeups received: {d}", .{self.wakeups}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = .dimmed },
        },
    });
    try row.close(frame);

    try frame.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(16) } });

    try frame.e(Text{
        .content = "each task sleeps 0..10 seconds. Wakeups land back on the main loop without blocking the UI.",
        .key = .src(@src()),
        .style = &.{ .font_size = .xs, .foreground = .dimmed },
    });
}

fn sleep10(self: *@This(), app: *knots.App, frame: *ui.Frame) !void {
    for (1..11) |i| {
        app.dispatch(
            app.main_viewport.id,
            doSleep,
            .{ app.io, @as(i64, @intCast(i)) },
            onWakeup,
        ) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                std.log.warn("async dispatch is unavailable because this build has no thread support", .{});
                if (self.pending > 0) frame.requestRedraw();
                return;
            },
            else => return err,
        };
        self.pending += 1;
    }
    frame.requestRedraw();
}

fn doSleep(io: std.Io, seconds: i64) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
}

fn onWakeup(view: *knots.View, frame: *ui.Frame, _: std.Io.Cancelable!void) !void {
    const self = &Playground.of(view.app).demos.async_dispatch;
    self.wakeups += 1;
    if (self.pending > 0) self.pending -= 1;
    frame.requestRedraw();
}
