const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const Self = @import("../root.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Spacer = ui.component.Spacer;

pub fn render(app: *knots.App, frame: *ui.Frame) !void {
    const self = Self.of(app);
    const arena = frame.arena();

    const row = Rect{ .key = .src(@src()), .style = &.{ .width = .grow(), .direction = .row, .gap = 12, .@"align" = .center } };
    _ = try row.open(frame);
    if ((try frame.interact(Button{
        .key = .src(@src()),
        .label = "sleep x10",
        .style = &.{ .width = .fixed(140), .height = .fixed(34) },
    })).clicked) try sleep10(self, app, frame);
    try frame.e(.{
        Text{
            .content = try std.fmt.allocPrint(arena, "pending: {d}", .{self.demo_state.pending_async}),
            .key = .src(@src()),
            .style = &.{ .font_size = .sm, .foreground = if (self.demo_state.pending_async > 0) .warning else .dimmed },
        },
        Text{
            .content = try std.fmt.allocPrint(arena, "wakeups received: {d}", .{self.demo_state.counter}),
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

fn sleep10(self: *Self, app: *knots.App, frame: *ui.Frame) !void {
    for (1..11) |i| {
        app.dispatch(
            app.main_viewport.id,
            doSleep,
            .{ self.io, @as(i64, @intCast(i)) },
            onWakeup,
        ) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                std.log.warn("async dispatch is unavailable because this build has no thread support", .{});
                if (self.demo_state.pending_async > 0) frame.requestRedraw();
                return;
            },
            else => return err,
        };
        self.demo_state.pending_async += 1;
    }
    frame.requestRedraw();
}

fn doSleep(io: std.Io, seconds: i64) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
}

fn onWakeup(view: *knots.View, frame: *ui.Frame, _: std.Io.Cancelable!void) !void {
    const self = Self.of(view.app);
    self.demo_state.counter += 1;
    if (self.demo_state.pending_async > 0) self.demo_state.pending_async -= 1;
    frame.requestRedraw();
}
