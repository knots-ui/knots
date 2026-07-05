const std = @import("std");
const knots = @import("knots");
const Self = @import("../root.zig");
const ui_helpers = @import("../ui_helpers.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const FloatingWindow = knots.component.FloatingWindow;
const Spacer = knots.component.Spacer;

const DEMO_TITLE = "Windows";
const PANEL_KEY = knots.ui.Key.str("panel:" ++ DEMO_TITLE);
const PanelBounds = @FieldType(knots.ui.State.Measured, "box");

pub fn render(app: *knots.App) !void {
    try ui_helpers.panel(app, DEMO_TITLE, body);
    try renderFloatingWindows(app);
}

fn body(app: *knots.App) !void {
    try app.e(.{
        Text{
            .content = "Open component-level floating windows or secondary native windows from the current app.",
            .width = .grow(),
            .wrap = true,
            .key = .src(@src()),
        },
        Spacer{ .height = .fixed(12), .key = .src(@src()) },
        Rect{
            .width = .grow(),
            .dir = .column,
            .gap = 8,
            .key = .src(@src()),
            .overflow = .scroll,
            .padding = .init(8, 8, 8, 8),
        },
        .{
            Button{
                .height = .fixed(32),
                .width = .fixed(176),
                .style = .{ .color = .secondary, .corner_radius = .sm },
                .hover_anim = .{},
                .key = .str("windows.open_floating_window"),
                .onClick = openFloatingWindow,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "open floating window" },
            },
            Button{
                .height = .fixed(32),
                .width = .fixed(176),
                .style = .{ .color = .primary, .corner_radius = .sm },
                .disabled_style = .{ .color = .muted, .corner_radius = .sm },
                .hover_anim = .{},
                .key = .src(@src()),
                .onClick = if (!knots.platform.is_browser_wasm) openNativeWindow else null,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "open native window" },
                .disabled = knots.platform.is_browser_wasm,
            },
        },
    });
}

fn renderFloatingWindows(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const ui = &app.viewport.ui;
    const measured = try ui.state.getOrCreate(.measured, ui.allocator, PANEL_KEY.hash());
    const bounds: ?PanelBounds = if (measured.width > 0 and measured.height > 0) measured.box else null;
    try app.e(.{
        FloatingWindow{
            .is_open = &self.demo_state.floating_window_open,
            .title = "Floating window",
            .key = .str("windows.floating_window"),
            .width = 420,
            .height = 260,
            .bounds = bounds,
            .content_gap = 12,
        },
        .{
            Text{
                .content = "Floating windows are UI components inside this viewport. Drag the title bar, resize from the lower-right corner, maximize, close, or click another window to raise it.",
                .width = .grow(),
                .wrap = true,
                .key = .str("windows.floating_window.description"),
            },
            Button{
                .height = .fixed(32),
                .width = .fixed(184),
                .style = .{ .color = .primary, .corner_radius = .sm },
                .hover_anim = .{},
                .key = .str("windows.floating_window.open_second"),
                .onClick = openSecondFloatingWindow,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "open another window" },
            },
        },
        FloatingWindow{
            .is_open = &self.demo_state.floating_window_second_open,
            .title = "Second floating window",
            .key = .str("windows.floating_window.second"),
            .width = 360,
            .height = 220,
            .bounds = bounds,
        },
        .{
            Text{
                .content = "This second component window uses the same viewport and UI state; clicking it raises it above the first.",
                .width = .grow(),
                .wrap = true,
                .key = .str("windows.floating_window.second.description"),
            },
        },
    });
}

fn openFloatingWindow(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.floating_window_open = true;
    app.requestFrame();
}

fn openSecondFloatingWindow(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.demo_state.floating_window_second_open = true;
    app.requestFrame();
}

fn openNativeWindow(app: *knots.App) !void {
    _ = try app.openWindow(.{
        .window = .{
            .width = 520,
            .height = 320,
            .title = "Knots native window",
        },
    }, nativeWindowFrame);
}

fn nativeWindowFrame(app: *knots.App) !void {
    const size = app.viewport.window.getSize();
    const size_label = try std.fmt.allocPrint(app.arena(), "Current size: {d} x {d}", .{ size.width, size.height });

    try app.e(.{
        Rect{
            .width = .fixed(@floatFromInt(size.width)),
            .height = .fixed(@floatFromInt(size.height)),
            .padding = .init(24, 24, 24, 24),
            .dir = .column,
            .gap = 12,
            .key = .str("windows.native_window.root"),
            .style = .{ .color = .bg, .corner_radius = .none },
        },
        .{
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
            Button{
                .height = .fixed(32),
                .width = .fixed(176),
                .style = .{ .color = .primary, .corner_radius = .sm },
                .hover_anim = .{},
                .key = .str("windows.native_window.open"),
                .onClick = openNativeWindow,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "open another window" },
            },
            Button{
                .height = .fixed(32),
                .width = .fixed(176),
                .style = .{ .color = .@"error", .corner_radius = .sm },
                .hover_anim = .{},
                .key = .str("windows.native_window.close"),
                .onClick = closeNativeWindow,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "close this window" },
            },
        },
    });
}

fn closeNativeWindow(app: *knots.App) !void {
    app.closeWindow();
}
