const std = @import("std");
const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");
const platform = knots.platform;

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;

const is_browser_wasm = platform.is_browser_wasm;

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(app, "Async dispatch", body);
}

fn body(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const arena = app.arena();

    try app.e(.{
        Rect{ .width = .grow(), .dir = .row, .gap = 12, .@"align" = .center, .key = .src(@src()) },
        .{
            Button{
                .key = .src(@src()),
                .width = .fixed(140),
                .height = .fixed(34),
                .style = .{ .color = .primary, .corner_radius = .sm },
                .hover_anim = .{},
                .justify = .center,
                .@"align" = .center,
                .onClick = sleep10,
                .text = .{ .content = if (is_browser_wasm) "dispatch x10" else "sleep x10" },
            },
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
        },
    });

    try app.e(Spacer{ .height = .fixed(16), .key = .src(@src()) });

    try app.e(Text{
        .content = if (is_browser_wasm)
            "browser wasm dispatch is cooperative, work must not block and completions land on the next frame."
        else
            "each task sleeps 0..10 seconds. Wakeups land back on the main loop without blocking the UI.",
        .size = .xs,
        .color = .dimmed,
        .key = .src(@src()),
    });

    if (self.demo_state.pending_async > 0) app.requestFrame();
}

fn sleep10(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);

    self.demo_state.pending_async += 10;
    for (1..11) |i| {
        if (is_browser_wasm)
            try app.dispatch(completeImmediately, .{}, onImmediateComplete)
        else
            try app.dispatch(
                doSleep,
                .{ self.io, @as(i64, @intCast(i)) },
                onWakeup,
            );
    }
    app.requestFrame();
}

fn completeImmediately() u8 {
    return 0;
}

fn onImmediateComplete(app: *knots.App, _: u8) !void {
    completeOne(app);
}

fn doSleep(io: std.Io, seconds: i64) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(seconds), .boot);
}

fn onWakeup(app: *knots.App, _: std.Io.Cancelable!void) !void {
    completeOne(app);
}

fn completeOne(app: *knots.App) void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.counter += 1;
    if (self.demo_state.pending_async > 0) self.demo_state.pending_async -= 1;
}
