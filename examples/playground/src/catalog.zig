pub const Entry = struct {
    /// A native demo declares `render(app, frame)` and runs in the host.
    /// Every other demo is an HMR module.
    module: type,
    name: []const u8,
    icon: []const u8,
    description: []const u8,
    /// The text of a native demo. Modules provide their own.
    source: []const u8 = "",
};

pub const entries = [_]Entry{
    .{ .module = @import("demos/buttons.zig"), .name = "Buttons", .icon = "\u{e913}", .description = "Button variants, click handlers, disabled state and a menu button." },
    .{ .module = @import("demos/context_menu.zig"), .name = "Context menu", .icon = "\u{e5d2}", .description = "Right-click wrapper component with custom user-defined actions." },
    .{ .module = @import("demos/layout.zig"), .name = "Layout", .icon = "\u{e8f1}", .description = "Sizing, nesting, cross-axis alignment and main-axis distribution." },
    .{ .module = @import("demos/control_flow.zig"), .name = "Control flow", .icon = "\u{e8d5}", .description = "For, VirtualList and component.Collapsible composed together." },
    .{ .module = @import("demos/form.zig"), .name = "Form", .icon = "\u{e890}", .description = "Text inputs, radio buttons, tooltip, dropdown and slider wired into a single form." },
    .{ .module = @import("demos/layer.zig"), .name = "Layer", .icon = "\u{e53b}", .description = "dir=.layer stacks children on the z-axis." },
    .{ .module = @import("demos/overflow.zig"), .name = "Overflow", .icon = "\u{e5d7}", .description = "visible, hidden, scroll_x and scroll_y side by side." },
    .{ .module = @import("demos/grid.zig"), .name = "Grid", .icon = "\u{e871}", .description = "Dashboard tiles using fr tracks and cell spans." },
    .{ .module = @import("demos/glass.zig"), .name = "Glass", .icon = "\u{e3a5}", .description = "Style.backdrop: blur, saturation and refraction over an animated scene." },
    .{ .module = @import("demos/canvas.zig"), .name = "Canvas", .icon = "\u{e3ae}", .description = "Painter primitives: gradient grid, clock face, bar chart, polygon." },
    .{ .module = @import("native_demos/gpu_shader.zig"), .source = @embedFile("native_demos/gpu_shader.zig"), .name = "GPU geometry", .icon = "\u{e1b1}", .description = "Thousands of indexed, instanced facets forming an interactive torus knot." },
    .{ .module = @import("native_demos/async_dispatch.zig"), .source = @embedFile("native_demos/async_dispatch.zig"), .name = "Async dispatch", .icon = "\u{e627}", .description = "Schedule background work via app.dispatch and react to wakeups." },
    .{ .module = @import("native_demos/windows.zig"), .source = @embedFile("native_demos/windows.zig"), .name = "Windows", .icon = "\u{e30c}", .description = "Floating windows in the current viewport and secondary native windows." },
    .{ .module = @import("demos/drops.zig"), .name = "Drops", .icon = "\u{e2c6}", .description = "Drag files onto the window and consume the paths from the frame input." },
    .{ .module = @import("demos/text_wrap.zig"), .name = "Text wrap", .icon = "\u{e25b}", .description = "Text and TextInput with wrap=true." },
    .{ .module = @import("demos/theme.zig"), .name = "Theme", .icon = "\u{e40a}", .description = "Switch UI theme at runtime between dark, light and the playground's custom theme." },
};
