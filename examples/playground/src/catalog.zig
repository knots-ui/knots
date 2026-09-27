const std = @import("std");

pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    icon: []const u8,
    description: []const u8,
};

pub const entries = [_]Entry{
    .{ .id = "demos/buttons", .name = "Buttons", .icon = "\u{e913}", .description = "Button variants, click handlers, disabled state and a menu button." },
    .{ .id = "demos/context_menu", .name = "Context menu", .icon = "\u{e5d2}", .description = "Right-click wrapper component with custom user-defined actions." },
    .{ .id = "demos/layout", .name = "Layout", .icon = "\u{e8f1}", .description = "Sizing, nesting, cross-axis alignment and main-axis distribution." },
    .{ .id = "demos/control_flow", .name = "Control flow", .icon = "\u{e8d5}", .description = "For, VirtualList and component.Collapsible composed together." },
    .{ .id = "demos/form", .name = "Form", .icon = "\u{e890}", .description = "Text inputs, radio buttons, tooltip, dropdown and slider wired into a single form." },
    .{ .id = "demos/layer", .name = "Layer", .icon = "\u{e53b}", .description = "dir=.layer stacks children on the z-axis." },
    .{ .id = "demos/overflow", .name = "Overflow", .icon = "\u{e5d7}", .description = "visible, hidden, scroll_x and scroll_y side by side." },
    .{ .id = "demos/grid", .name = "Grid", .icon = "\u{e871}", .description = "Dashboard tiles using fr tracks and cell spans." },
    .{ .id = "demos/glass", .name = "Glass", .icon = "\u{e3a5}", .description = "Style.backdrop: blur, saturation and refraction over an animated scene." },
    .{ .id = "demos/canvas", .name = "Canvas", .icon = "\u{e3ae}", .description = "Painter primitives: gradient grid, clock face, bar chart, polygon." },
    .{ .id = "native/gpu_shader", .name = "GPU geometry", .icon = "\u{e1b1}", .description = "Thousands of indexed, instanced facets forming an interactive torus knot." },
    .{ .id = "native/async_dispatch", .name = "Async dispatch", .icon = "\u{e627}", .description = "Schedule background work via app.dispatch and react to wakeups." },
    .{ .id = "native/windows", .name = "Windows", .icon = "\u{e30c}", .description = "Floating windows in the current viewport and secondary native windows." },
    .{ .id = "demos/drops", .name = "Drops", .icon = "\u{e2c6}", .description = "Drag files onto the window and consume the paths from the frame input." },
    .{ .id = "demos/text_wrap", .name = "Text wrap", .icon = "\u{e25b}", .description = "Text and TextInput with wrap=true." },
    .{ .id = "demos/theme", .name = "Theme", .icon = "\u{e40a}", .description = "Switch UI theme at runtime between dark, light and the playground's custom theme." },
};

pub fn find(id: []const u8) ?Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}
