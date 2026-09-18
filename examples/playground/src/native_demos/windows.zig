const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const FloatingWindow = ui.component.FloatingWindow;
const Spacer = ui.component.Spacer;

const DEMO_TITLE = "Windows";
const PANEL_KEY = ui.Key.str("panel:" ++ DEMO_TITLE);
const PanelBounds = @FieldType(ui.State.Measured, "box");

pub fn render(desktop: *knots.App, app: *ui.Frame) !void {
    try ui_helpers.panel(desktop, app, DEMO_TITLE, body);
    try renderFloatingWindows(desktop, app);
}

fn body(desktop: *knots.App, app: *ui.Frame) !void {
    const self = Self.of(desktop);
    try app.e(.{
        Text{
            .content = "Open component-level floating windows or secondary native windows from the current app.",
            .width = .grow(),
            .wrap = true,
            .key = .src(@src()),
        },
        Spacer{ .height = .fixed(12), .key = .src(@src()) },
    });
    const actions = Rect{
        .width = .grow(),
        .dir = .column,
        .gap = 8,
        .key = .src(@src()),
        .overflow = .scroll,
        .padding = .init(8, 8, 8, 8),
    };
    _ = try actions.open(app);
    const floating = try app.interact(Button{
        .height = .fixed(32),
        .width = .fixed(176),
        .style = .{ .color = .secondary, .corner_radius = .sm },
        .hover_anim = .{},
        .key = .str("windows.open_floating_window"),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "open floating window" },
    });
    if (floating.clicked) {
        self.demo_state.floating_window_open = true;
        app.requestRedraw();
    }
    const native = try app.interact(Button{
        .height = .fixed(32),
        .width = .fixed(176),
        .style = .{ .color = .primary, .corner_radius = .sm },
        .disabled_style = .{ .color = .muted, .corner_radius = .sm },
        .hover_anim = .{},
        .key = .src(@src()),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "open native window" },
        .disabled = knots.platform.is_browser_wasm,
    });
    if (native.clicked) try openNativeWindow(self);
    try actions.close(app);
}

fn renderFloatingWindows(desktop: *knots.App, app: *ui.Frame) !void {
    const self = Self.of(desktop);
    const measured = try app.ui().state.getOrCreate(.measured, app.ui().allocator, PANEL_KEY.hash());
    const bounds: ?PanelBounds = if (measured.width > 0 and measured.height > 0) measured.box else null;
    const first = FloatingWindow{
        .is_open = &self.demo_state.floating_window_open,
        .title = "Floating window",
        .key = .str("windows.floating_window"),
        .width = 420,
        .height = 260,
        .bounds = bounds,
        .content_gap = 12,
    };
    if ((try first.openResponse(app)).id != ui.UI.INVALID_ID) {
        try app.e(Text{
            .content = "Floating windows are UI components inside this viewport. Drag the title bar, resize from the lower-right corner, maximize, close, or click another window to raise it.",
            .width = .grow(),
            .wrap = true,
            .key = .str("windows.floating_window.description"),
        });
        const second = try app.interact(Button{
            .height = .fixed(32),
            .width = .fixed(184),
            .style = .{ .color = .primary, .corner_radius = .sm },
            .hover_anim = .{},
            .key = .str("windows.floating_window.open_second"),
            .justify = .center,
            .@"align" = .center,
            .text = .{ .content = "open another window" },
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
        .width = 360,
        .height = 220,
        .bounds = bounds,
    };
    if ((try second.openResponse(app)).id != ui.UI.INVALID_ID) {
        try app.e(Text{
            .content = "This second component window uses the same viewport and UI state; clicking it raises it above the first.",
            .width = .grow(),
            .wrap = true,
            .key = .str("windows.floating_window.second.description"),
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
        .width = .fixed(@floatFromInt(size.width)),
        .height = .fixed(@floatFromInt(size.height)),
        .padding = .init(24, 24, 24, 24),
        .dir = .column,
        .gap = 12,
        .key = .str("windows.native_window.root"),
        .style = .{ .color = .bg, .corner_radius = .none },
    };
    _ = try root.open(frame);
    try frame.e(.{
        Text{
            .content = "Secondary native window",
            .size = .lg,
            .key = .str("windows.native_window.title"),
        },
        Text{
            .content = size_label,
            .color = .dimmed,
            .key = .str("windows.native_window.size"),
        },
        Text{
            .content = "Native windows are secondary viewports with their own OS window, renderer, UI state, timer, and frame callback. They share the same app state and renderer group.",
            .width = .grow(),
            .wrap = true,
            .key = .str("windows.native_window.description"),
        },
        Spacer{ .height = .fixed(4), .key = .str("windows.native_window.spacer") },
    });
    if ((try frame.interact(Button{
        .height = .fixed(32),
        .width = .fixed(176),
        .style = .{ .color = .primary, .corner_radius = .sm },
        .hover_anim = .{},
        .key = .str("windows.native_window.open"),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "open another window" },
    })).clicked) try openNativeWindow(self);
    if ((try frame.interact(Button{
        .height = .fixed(32),
        .width = .fixed(176),
        .style = .{ .color = .@"error", .corner_radius = .sm },
        .hover_anim = .{},
        .key = .str("windows.native_window.close"),
        .justify = .center,
        .@"align" = .center,
        .text = .{ .content = "close this window" },
    })).clicked) frame.requestClose();
    try root.close(frame);
}
