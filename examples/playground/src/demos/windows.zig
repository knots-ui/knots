const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const Playground = @import("../Playground.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const FloatingWindow = ui.component.FloatingWindow;
const TitleBar = ui.component.TitleBar;
const Dialog = ui.component.Dialog;
const Spacer = ui.component.Spacer;

const PanelBounds = @FieldType(ui.State.Measured, "box");

floating_open: bool = false,
second_floating_open: bool = false,
dialog_open: bool = false,

pub fn render(self: *@This(), app: *knots.App, frame: *ui.Frame) !void {
    try frame.e(.{
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
    _ = try actions.open(frame);
    const floating = try frame.interact(Button{
        .key = .str("windows.open_floating_window"),
        .label = "open floating window",
        .style = &.{ .height = .fixed(32), .width = .fixed(176), .tone = .secondary },
    });
    if (floating.clicked) {
        self.floating_open = true;
        frame.requestRedraw();
    }
    const native = try frame.interact(Button{
        .key = .src(@src()),
        .label = "open native window",
        .disabled = !knots.platform.secondary_windows,
        .style = &.{ .height = .fixed(32), .width = .fixed(176), .disabled = &.{ .background = .muted, .foreground = .text } },
    });
    if (native.clicked) try openNativeWindow(app);
    const undecorated = try frame.interact(Button{
        .key = .src(@src()),
        .label = "open custom title bar",
        .disabled = !knots.platform.secondary_windows,
        .style = &.{ .height = .fixed(32), .width = .fixed(176), .disabled = &.{ .background = .muted, .foreground = .text } },
    });
    if (undecorated.clicked) try openUndecoratedWindow(app);
    try actions.close(frame);
    try self.renderFloatingWindows(frame);
}

fn renderFloatingWindows(self: *@This(), frame: *ui.Frame) !void {
    const measured = try frame.ui().state.getOrCreate(.measured, frame.ui().allocator, Playground.demo_panel_key.hash());
    const bounds: ?PanelBounds = if (measured.width > 0 and measured.height > 0) measured.box else null;
    const first = FloatingWindow{
        .is_open = &self.floating_open,
        .title = "Floating window",
        .key = .str("windows.floating_window"),
        .initial_size = .{ 420, 260 },
        .bounds = bounds,
        .parts = .{ .content = &.{ .gap = 12 } },
    };
    if ((try first.openResponse(frame)).id != ui.UI.INVALID_ID) {
        try frame.e(Text{
            .content = "Floating windows are UI components inside this viewport. Drag the title bar, resize from the lower-right corner, maximize, close, or click another window to raise it.",
            .key = .str("windows.floating_window.description"),
            .style = &.{ .width = .grow(), .wrap = true },
        });
        const second = try frame.interact(Button{
            .key = .str("windows.floating_window.open_second"),
            .label = "open another window",
            .style = &.{ .height = .fixed(32), .width = .fixed(184) },
        });
        if (second.clicked) {
            self.second_floating_open = true;
            frame.requestRedraw();
        }
        _ = try first.closeResponse(frame);
    }

    const second = FloatingWindow{
        .is_open = &self.second_floating_open,
        .title = "Second floating window",
        .key = .str("windows.floating_window.second"),
        .initial_size = .{ 360, 220 },
        .bounds = bounds,
    };
    if ((try second.openResponse(frame)).id != ui.UI.INVALID_ID) {
        try frame.e(Text{
            .content = "This second component window uses the same viewport and UI state; clicking it raises it above the first.",
            .key = .str("windows.floating_window.second.description"),
            .style = &.{ .width = .grow(), .wrap = true },
        });
        _ = try second.closeResponse(frame);
    }
}

fn openNativeWindow(app: *knots.App) !void {
    _ = try app.openWindow(app.main_viewport.id, .{
        .window = .{
            .width = 520,
            .height = 320,
            .title = "Knots native window",
        },
    }, nativeWindowFrame);
}

fn nativeWindowFrame(view: *knots.View, frame: *ui.Frame) !void {
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
    })).clicked) try openNativeWindow(view.app);
    if ((try frame.interact(Button{
        .key = .str("windows.native_window.close"),
        .label = "close this window",
        .style = &.{ .height = .fixed(32), .width = .fixed(176), .tone = .@"error" },
    })).clicked) frame.requestClose();
    try root.close(frame);
}

fn openUndecoratedWindow(app: *knots.App) !void {
    _ = try app.openWindow(app.main_viewport.id, .{
        .window = .{
            .width = 560,
            .height = 360,
            .title = "Knots custom title bar",
            .decorations = .none,
        },
    }, undecoratedWindowFrame);
}

fn undecoratedWindowFrame(view: *knots.View, frame: *ui.Frame) !void {
    const self = &Playground.of(view.app).demos.windows;
    const size = frame.input().logical_extent;

    const root = Rect{
        .key = .str("windows.undecorated.root"),
        .style = &.{ .width = .fixed(@floatFromInt(size.width)), .height = .fixed(@floatFromInt(size.height)), .direction = .column, .background = .bg, .radius = .none },
    };
    _ = try root.open(frame);

    const bar = TitleBar{ .key = .str("windows.undecorated.title_bar"), .title = "Custom title bar" };
    _ = try bar.open(frame);
    _ = try frame.interact(Button{
        .key = .str("windows.undecorated.title_bar.action"),
        .label = "action",
        .style = &.{ .height = .fixed(24), .padding = .xy(10, 0), .tone = .secondary },
    });
    try bar.close(frame);

    const content = Rect{
        .key = .str("windows.undecorated.content"),
        .style = &.{ .width = .grow(), .height = .grow(), .padding = .all(24), .direction = .column, .gap = 12 },
    };
    _ = try content.open(frame);
    try frame.e(Text{
        .content = "This window has no platform title bar. Drag the bar to move it, double-click it to maximize, and resize from the edges. The window buttons keep working while the dialog is open.",
        .key = .str("windows.undecorated.description"),
        .style = &.{ .width = .grow(), .wrap = true },
    });
    if ((try frame.interact(Button{
        .key = .str("windows.undecorated.open_dialog"),
        .label = "open dialog",
        .style = &.{ .height = .fixed(32), .width = .fixed(176) },
    })).clicked) self.dialog_open = true;
    try content.close(frame);

    const dialog = Dialog{ .is_open = &self.dialog_open, .key = .str("windows.undecorated.dialog") };
    if (try dialog.open(frame) != ui.UI.INVALID_ID) {
        try frame.e(Text{
            .content = "A modal dialog. Press Escape or click outside to close it.",
            .key = .str("windows.undecorated.dialog.text"),
        });
    }
    try dialog.close(frame);

    try root.close(frame);
}
