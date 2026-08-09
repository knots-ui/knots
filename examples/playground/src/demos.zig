const std = @import("std");
const knots = @import("knots");
const renderer = @import("renderer");

pub const Demo = struct {
    name: []const u8,
    description: []const u8,
    source_path: []const u8,
    source: [:0]const u8,
    render: *const fn (*knots.App, *knots.Frame) anyerror!void,

    pub const State = struct {
        pub const GpuResources = struct {
            pipeline: renderer.gpu.Pipeline,
            vertex_buffer: renderer.gpu.Buffer,
            index_buffer: renderer.gpu.Buffer,
            instance_buffer: renderer.gpu.Buffer,

            pub fn deinit(self: *GpuResources) void {
                self.instance_buffer.deinit();
                self.index_buffer.deinit();
                self.vertex_buffer.deinit();
                self.pipeline.deinit();
            }
        };

        counter: isize = 0,
        counter_items: std.ArrayList(isize) = .empty,
        show_details: bool = true,
        name_buf: std.ArrayList(u8) = .empty,
        slider_value: f32 = 0.5,
        form_email: std.ArrayList(u8) = .empty,
        form_password: std.ArrayList(u8) = .empty,
        form_role: u32 = 0,
        form_notifications_enabled: bool = true,
        form_delivery_cadence: u32 = 1,
        form_volume: f32 = 0.7,
        form_color: knots.ui.Color = knots.ui.Color.hex("#4F8CFFFF") catch unreachable,
        form_confirm_open: bool = false,
        canvas_effect: u32 = 0,
        gpu_resources: ?GpuResources = null,
        gpu_time: f32 = 0,
        gpu_orbit: f32 = 0,
        gpu_camera: [2]f32 = .{ 0.35, -0.2 },
        gpu_drag_position: [2]f32 = .{ 0, 0 },
        gpu_dragging: bool = false,
        gpu_density: f32 = 4096,
        gpu_strand_width: f32 = 0.14,
        gpu_facet_size: f32 = 1.0,
        gpu_twist: f32 = 3.0,
        gpu_zoom: f32 = 1.0,
        gpu_perspective: f32 = 48,
        gpu_spin: f32 = 0.32,
        pending_async: usize = 0,
        dropped_paths: std.ArrayList([]const u8) = .empty,
        notes_buf: std.ArrayList(u8) = .empty,
        theme_idx: u32 = 1,
        context_menu_last_action: []const u8 = "none",
        context_menu_last_target: []const u8 = "none",
        menu_button_last_action: []const u8 = "none",
        floating_window_open: bool = false,
        floating_window_second_open: bool = false,
        show_source: bool = true,

        pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
            if (self.gpu_resources) |*resources| resources.deinit();
            self.notes_buf.deinit(allocator);
            for (self.dropped_paths.items) |p| allocator.free(p);
            self.dropped_paths.deinit(allocator);
            self.form_password.deinit(allocator);
            self.form_email.deinit(allocator);
            self.name_buf.deinit(allocator);
            self.counter_items.deinit(allocator);
        }
    };
};

fn demo(
    comptime path: []const u8,
    comptime icon: []const u8,
    comptime name: []const u8,
    comptime description: []const u8,
    comptime render: *const fn (*knots.App, *knots.Frame) anyerror!void,
) Demo {
    return .{
        .name = icon ++ " " ++ name,
        .description = description,
        .source_path = "examples/playground/src/" ++ path,
        .source = @embedFile(path),
        .render = render,
    };
}

pub const all = [_]Demo{
    demo("demos/buttons.zig", "\u{e913}", "Buttons", "Button variants, click handlers, disabled state and a menu button.", @import("demos/buttons.zig").render),
    demo("demos/context_menu.zig", "\u{e5d2}", "Context menu", "Right-click wrapper component with custom user-defined actions.", @import("demos/context_menu.zig").render),
    demo("demos/layout.zig", "\u{e8f1}", "Layout", "Sizing, nesting, cross-axis alignment and main-axis distribution.", @import("demos/layout.zig").render),
    demo("demos/control_flow.zig", "\u{e8d5}", "Control flow", "For, VirtualList and animation.Collapsible composed together.", @import("demos/control_flow.zig").render),
    demo("demos/form.zig", "\u{e890}", "Form", "Text inputs, radio buttons, tooltip, dropdown and slider wired into a single form.", @import("demos/form.zig").render),
    demo("demos/layer.zig", "\u{e53b}", "Layer", "dir=.layer stacks children on the z-axis.", @import("demos/layer.zig").render),
    demo("demos/overflow.zig", "\u{e5d7}", "Overflow", "visible, hidden, scroll_x and scroll_y side by side.", @import("demos/overflow.zig").render),
    demo("demos/grid.zig", "\u{e871}", "Grid", "Dashboard tiles using fr tracks and cell spans.", @import("demos/grid.zig").render),
    demo("demos/canvas.zig", "\u{e3ae}", "Canvas", "Painter primitives: gradient grid, clock face, bar chart, polygon.", @import("demos/canvas.zig").render),
    demo("demos/gpu_shader.zig", "\u{e1b1}", "GPU geometry", "Knot Laboratory: thousands of indexed, instanced facets forming an interactive torus knot.", @import("demos/gpu_shader.zig").render),
    demo("demos/async_dispatch.zig", "\u{e627}", "Async dispatch", "Schedule background work via app.dispatch and react to wakeups.", @import("demos/async_dispatch.zig").render),
    demo("demos/windows.zig", "\u{e30c}", "Windows", "Floating windows in the current viewport and secondary native windows.", @import("demos/windows.zig").render),
    demo("demos/drops.zig", "\u{e2c6}", "Drops", "Drag files onto the window and consume them via app.viewport.window.consumeDrops.", @import("demos/drops.zig").render),
    demo("demos/text_wrap.zig", "\u{e25b}", "Text wrap", "Text and TextInput with wrap=true.", @import("demos/text_wrap.zig").render),
    demo("demos/theme.zig", "\u{e40a}", "Theme", "Switch UI theme at runtime between dark, light and the playground's custom theme.", @import("demos/theme.zig").render),
};
