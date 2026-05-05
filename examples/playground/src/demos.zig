const std = @import("std");
const knots = @import("knots");

pub const Demo = struct {
    name: []const u8,
    description: []const u8,
    render: *const fn (*knots.App) anyerror!void,

    pub const State = struct {
        counter: isize = 0,
        counter_items: std.ArrayList(isize) = .empty,
        show_details: bool = true,
        name_buf: std.ArrayList(u8) = .empty,
        slider_value: f32 = 0.5,
        form_email: std.ArrayList(u8) = .empty,
        form_password: std.ArrayList(u8) = .empty,
        form_role: u32 = 0,
        form_volume: f32 = 0.7,
        canvas_effect: u32 = 0,
        canvas_cmds: std.ArrayList(knots.component.Canvas.DrawCmd) = .empty,
        pending_async: usize = 0,
        hover_strength: f32 = 0,

        pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
            self.canvas_cmds.deinit(allocator);
            self.form_password.deinit(allocator);
            self.form_email.deinit(allocator);
            self.name_buf.deinit(allocator);
            self.counter_items.deinit(allocator);
        }
    };
};

pub const all = [_]Demo{
    .{
        .name = "Buttons",
        .description = "Click handlers, hover animations, corner radii.",
        .render = @import("demos/buttons.zig").render,
    },
    .{
        .name = "Sizing",
        .description = "grow, fixed, percent and fit on the same axis.",
        .render = @import("demos/sizing.zig").render,
    },
    .{
        .name = "Nesting",
        .description = "Three levels of nested containers with shared layout.",
        .render = @import("demos/nesting.zig").render,
    },
    .{
        .name = "Alignment",
        .description = "Cross-axis alignment: start, center, end.",
        .render = @import("demos/alignment.zig").render,
    },
    .{
        .name = "Justify",
        .description = "Main-axis distribution: start, center, end, space_between, space_around.",
        .render = @import("demos/justify.zig").render,
    },
    .{
        .name = "Control flow",
        .description = "If, For and animation.Collapsible composed together.",
        .render = @import("demos/control_flow.zig").render,
    },
    .{
        .name = "Slider",
        .description = "SliderInput drives a live readout and a colored bar.",
        .render = @import("demos/slider.zig").render,
    },
    .{
        .name = "Form",
        .description = "Text inputs, dropdown and slider wired into a single form.",
        .render = @import("demos/form.zig").render,
    },
    .{
        .name = "Layer",
        .description = "dir=.layer stacks children on the z-axis.",
        .render = @import("demos/layer.zig").render,
    },
    .{
        .name = "Overflow",
        .description = "visible, hidden, scroll_x and scroll_y side by side.",
        .render = @import("demos/overflow.zig").render,
    },
    .{
        .name = "Grid",
        .description = "Dashboard tiles using fr tracks and cell spans.",
        .render = @import("demos/grid.zig").render,
    },
    .{
        .name = "Virtual list",
        .description = "100,000 rows scrolled smoothly via VirtualList.",
        .render = @import("demos/virtual_list.zig").render,
    },
    .{
        .name = "Hover",
        .description = "Button hover animation, hover_style and a custom ui.anim() channel.",
        .render = @import("demos/hover.zig").render,
    },
    .{
        .name = "Canvas",
        .description = "Painter primitives: gradient grid, clock face, bar chart, polygon.",
        .render = @import("demos/canvas.zig").render,
    },
    .{
        .name = "Async dispatch",
        .description = "Schedule background work via app.dispatch and react to wakeups.",
        .render = @import("demos/async_dispatch.zig").render,
    },
};
