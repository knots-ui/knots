const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const Self = @import("../root.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const FloatingWindow = ui.component.FloatingWindow;
const Spacer = ui.component.Spacer;

const PanelBounds = @FieldType(ui.State.Measured, "box");

pub fn render(desktop: *knots.App, app: *ui.Frame) !void {
    const self = Self.of(desktop);
    try app.e(.{
        Text{
            .content = "Open component-level floating windows or secondary native windows from the current app.",
            .key = .src(@src()),
            .style = &.{ .width = .grow(), .wrap = true },
        },
        Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(12) } },
    });
    const actions = Rect{
        .key = .src(@src()),
        .style = &.{ .width = .grow(), .direction = .column, .gap = 8, .overflow = .scroll, .padding = .init(8, 8, 8, 8) },
    };
    _ = try actions.open(app);
    const floating = try app.interact(Button{
        .key = .str("windows.open_floating_window"),
        .label = "open floating window",
        .style = &.{ .height = .fixed(32), .width = .fixed(176), .tone = .secondary },
    });
    if (floating.clicked) {
        self.demo_state.floating_window_open = true;
        app.requestRedraw();
    }
    const native = try app.interact(Button{
        .key = .src(@src()),
        .label = "open native window",
        .disabled = !knots.platform.secondary_windows,
        .style = &.{ .height = .fixed(32), .width = .fixed(176), .disabled = &.{ .background = .muted, .foreground = .text } },
    });
    if (native.clicked) try openNativeWindow(self);
    try actions.close(app);
    try renderFloatingWindows(desktop, app);
}

fn renderFloatingWindows(desktop: *knots.App, app: *ui.Frame) !void {
    const self = Self.of(desktop);
    const measured = try app.ui().state.getOrCreate(.measured, app.ui().allocator, Self.demo_panel_key.hash());
    const bounds: ?PanelBounds = if (measured.width > 0 and measured.height > 0) measured.box else null;
    const first = FloatingWindow{
        .is_open = &self.demo_state.floating_window_open,
        .title = "Floating window",
        .key = .str("windows.floating_window"),
        .initial_size = .{ 420, 260 },
        .bounds = bounds,
        .parts = .{ .content = &.{ .gap = 12 } },
    };
    if ((try first.openResponse(app)).id != ui.UI.INVALID_ID) {
        try app.e(Text{
            .content = "Floating windows are UI components inside this viewport. Drag the title bar, resize from the lower-right corner, maximize, close, or click another window to raise it.",
            .key = .str("windows.floating_window.description"),
            .style = &.{ .width = .grow(), .wrap = true },
        });
        const second = try app.interact(Button{
            .key = .str("windows.floating_window.open_second"),
            .label = "open another window",
            .style = &.{ .height = .fixed(32), .width = .fixed(184) },
        });
        if (second.clicked) {
            self.demo_state.floating_window_second_open = true;
            app.requestRedraw();
        }
        _ = try first.closeResponse(app);
    }

    const second = FloatingWindow{
        .is_open = &self.demo_state.floating_window_second_open,
        .title = "Second floating window",
        .key = .str("windows.floating_window.second"),
        .initial_size = .{ 360, 220 },
        .bounds = bounds,
    };
    if ((try second.openResponse(app)).id != ui.UI.INVALID_ID) {
        try app.e(Text{
            .content = "This second component window uses the same viewport and UI state; clicking it raises it above the first.",
            .key = .str("windows.floating_window.second.description"),
            .style = &.{ .width = .grow(), .wrap = true },
        });
        _ = try second.closeResponse(app);
    }
}

fn openNativeWindow(self: *Self) !void {
    _ = try self.app.openWindow(self.app.main_viewport.id, .{
        .window = .{
            .width = 520,
            .height = 320,
            .title = "Knots native window",
        },
    }, nativeWindowFrame);
}

fn nativeWindowFrame(view: *knots.View, frame: *ui.Frame) !void {
    const self = Self.of(view.app);
    const size = frame.input().logical_extent;
    const size_label = try std.fmt.allocPrint(frame.arena(), "Current size: {d} x {d}", .{ size.width, size.height });

    const root = Rect{
        .key = .str("windows.native_window.root"),
        .style = &.{ .width = .fixed(@floatFromInt(size.width)), .height = .fixed(@floatFromInt(size.height)), .padding = .init(24, 24, 24, 24), .direction = .column, .gap = 12, .background = .bg, .radius = .none },
    };
    _ = try root.open(frame);
    try frame.e(.{
        Text{
            .content = "Secondary native window",
            .key = .str("windows.native_window.title"),
            .style = &.{ .font_size = .lg },
        },
        Text{
            .content = size_label,
            .key = .str("windows.native_window.size"),
            .style = &.{ .foreground = .dimmed },
        },
        Text{
            .content = "Native windows are secondary viewports with their own OS window, renderer, UI state, timer, and frame callback. They share the same app state and renderer group.",
            .key = .str("windows.native_window.description"),
            .style = &.{ .width = .grow(), .wrap = true },
        },
        Spacer{ .key = .str("windows.native_window.spacer"), .style = &.{ .height = .fixed(4) } },
    });
    if ((try frame.interact(Button{
        .key = .str("windows.native_window.open"),
        .label = "open another window",
        .style = &.{ .height = .fixed(32), .width = .fixed(176) },
    })).clicked) try openNativeWindow(self);
    if ((try frame.interact(Button{
        .key = .str("windows.native_window.close"),
        .label = "close this window",
        .style = &.{ .height = .fixed(32), .width = .fixed(176), .tone = .@"error" },
    })).clicked) frame.requestClose();
    try root.close(frame);
}
