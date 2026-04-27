const std = @import("std");
const knots = @import("knots");
const Rect = knots.component.Rect;
const Text = knots.component.Text;
const TextInput = knots.component.TextInput;
const SelectInput = knots.component.SelectInput;
const Button = knots.component.Button;
const Spacer = knots.component.Spacer;
const Canvas = knots.component.Canvas;
const For = knots.control.For;
const animation = knots.animation;

const is_emscripten = @import("builtin").os.tag == .emscripten;

extern fn emscripten_console_log(utf8: [*:0]const u8) void;

pub const std_options: std.Options = .{
    .logFn = if (is_emscripten) webLog else std.log.defaultLog,
};

fn webLog(comptime _: std.log.Level, comptime _: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrintSentinel(std.heap.c_allocator, format, args, 0x00) catch return;
    defer std.heap.c_allocator.free(msg);
    emscripten_console_log(msg.ptr);
}

const Fruit = enum {
    apple,
    banana,
    cherry,
    dragonfruit,
};

io: std.Io,
allocator: std.mem.Allocator,
app: knots.App,
renderer_settings: knots.debug.RendererSettings,
cntr: isize = 0,
counter_items: std.ArrayList(isize) = .empty,
show_details: bool = true,
details_tween_h: f32 = 0,
name_buf: std.ArrayList(u8),
grid_cmds: std.ArrayList(Canvas.DrawCmd),

const Self = @This();

pub fn init(io: std.Io, allocator: std.mem.Allocator) !Self {
    const app = try knots.App.init(io, allocator, .{
        .window = .{
            .width = 1280,
            .height = 720,
            .title = "Playground",
            .canvas_selector = "#canvas",
        },
        .renderer = .{ .present_mode = .fifo },
        .ui = .{
            .fonts = &.{
                .{ "default", @embedFile("fonts/Manrope-Regular.ttf") },
                .{ "icons", @embedFile("fonts/MaterialIcons-Regular.ttf") },
            },
        },
    });

    return Self{
        .io = io,
        .allocator = allocator,
        .app = app,
        .renderer_settings = try .init(allocator, app.renderer.cfg.gpu_backend, app.renderer.cfg.present_mode),
        .name_buf = try .initCapacity(allocator, 256),
        .grid_cmds = .empty,
    };
}

pub fn deinit(self: *Self) void {
    self.grid_cmds.deinit(self.allocator);
    self.name_buf.deinit(self.allocator);
    self.counter_items.deinit(self.allocator);
    self.renderer_settings.deinit(self.allocator);
    self.app.deinit();
}

pub fn start(self: *Self) !void {
    try self.app.start(frameCb);
}

pub fn frameCb(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const arena = app.arena();

    const size = app.window.getSize();
    return app.e(
        .{
            Rect{
                .width = .fixed(@floatFromInt(size.width)),
                .height = .fixed(@floatFromInt(size.height)),
                .padding = .init(16, 16, 16, 16),
                .dir = .column,
                .key = .src(@src()),
            },
            .{
                Rect{
                    .width = .grow(),
                    .height = .fixed(48),
                    .padding = .init(8, 16, 8, 16),
                    .dir = .row,
                    .justify = .space_between,
                    .@"align" = .center,
                    .key = .src(@src()),
                    .style = .{
                        .color = .bg,
                        .border_width = 1,
                        .border_color = .toned,
                    },
                },
                .{
                    Rect{
                        .width = .fit(),
                        .height = .fit(),
                        .dir = .row,
                        .@"align" = .center,
                        .gap = 2,
                        .key = .src(@src()),
                    },
                    .{
                        Text{
                            .content = "\u{e88a}",
                            .font = "icons",
                            .size = 24,
                            .key = .src(@src()),
                        },
                        Text{
                            .content = try std.fmt.allocPrint(arena, "knots playground - {s}", .{@tagName(app.renderer.cfg.gpu_backend)}),
                            .size = 24,
                            .key = .src(@src()),
                        },
                    },
                    Rect{
                        .width = .fit(),
                        .height = .fit(),
                        .dir = .row,
                        .@"align" = .center,
                        .key = .src(@src()),
                    },
                    .{
                        Text{
                            .content = try std.fmt.allocPrint(arena, "counter: {d}", .{self.cntr}),
                            .size = 14,
                            .color = .dimmed,
                            .key = .src(@src()),
                        },
                        Spacer{ .width = .fixed(16), .key = .src(@src()) },
                        Rect{
                            .width = .fit(),
                            .height = .fit(),
                            .dir = .row,
                            .@"align" = .center,
                            .key = .src(@src()),
                            .gap = 8,
                        },
                        .{self.renderer_settings},
                    },
                },
                Spacer{ .height = .fixed(12), .key = .src(@src()) },
                Rect{
                    .width = .grow(),
                    .height = .grow(),
                    .dir = .row,
                    .key = .src(@src()),
                },
                .{
                    .{
                        Rect{
                            .width = .fixed(320),
                            .height = .grow(),
                            .padding = .init(12, 12, 12, 12),
                            .dir = .column,
                            .overflow = .scroll_y,
                            .key = .src(@src()),
                            .style = .{
                                .color = .bg,
                                .border_width = 1,
                                .border_color = .toned,
                            },
                        },
                        .{
                            renderSectionButtons,
                            Spacer{ .height = .fixed(16), .key = .src(@src()) },
                            renderSectionSizing,
                            Spacer{ .height = .fixed(16), .key = .src(@src()) },
                            renderSectionNesting,
                            Spacer{ .height = .fixed(16), .key = .src(@src()) },
                            renderSectionAlignment,
                            Spacer{ .height = .fixed(16), .key = .src(@src()) },
                            renderSectionControlFlow,
                            Spacer{ .height = .fixed(16), .key = .src(@src()) },
                            renderSectionInputs,
                        },
                    },
                    Spacer{ .width = .fixed(12), .key = .src(@src()) },
                    Rect{
                        .width = .grow(),
                        .height = .grow(),
                        .overflow = .scroll_y,
                        .key = .src(@src()),
                        .style = .{
                            .color = .bg,
                            .border_width = 1,
                            .border_color = .toned,
                        },
                        .dir = .column,
                    },
                    .{renderGrid},
                },
            },
        },
    );
}

fn renderSectionButtons(app: *knots.App) anyerror!void {
    try app.e(.{
        Text{
            .content = "Buttons",
            .size = 16,
            .key = .src(@src()),
        },
        Spacer{ .height = .fixed(8), .key = .src(@src()) },
        Rect{
            .width = .grow(),
            .height = .fit(),
            .dir = .row,
            .key = .src(@src()),
        },
        .{
            Button{
                .height = .fixed(30),
                .width = .fixed(65),
                .style = .{ .color = .success, .corner_radius = .sm },
                .key = .src(@src()),
                .onClick = increment,
                .justify = .center,
                .@"align" = .center,
                .hover_anim = .{},
                .text = .{ .content = "+1" },
            },
            Spacer{ .width = .fixed(6), .key = .src(@src()) },
            Button{
                .height = .fixed(30),
                .width = .fixed(65),
                .style = .{ .color = .@"error", .corner_radius = .sm },
                .key = .src(@src()),
                .onClick = decrement,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "-1" },
            },
            Spacer{ .width = .fixed(6), .key = .src(@src()) },
            Button{
                .height = .fixed(30),
                .width = .fixed(65),
                .style = .{ .color = .@"error", .corner_radius = .{ .fixed = 15 } },
                .key = .src(@src()),
                .onClick = exit,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "exit" },
            },
            Spacer{ .width = .fixed(6), .key = .src(@src()) },
            Button{
                .height = .fixed(30),
                .width = .fixed(65),
                .style = .{
                    .color = .{ .color = .rgba(0, 0, 0, 0) },
                    .corner_radius = .sm,
                    .border_width = 1,
                    .border_color = .dimmed,
                },
                .key = .src(@src()),
                .onClick = sleep,
                .justify = .center,
                .@"align" = .center,
                .text = .{ .content = "sleep +50", .size = 9 },
            },
        },
    });
}

fn renderSectionSizing(app: *knots.App) anyerror!void {
    try app.e(.{
        Text{ .content = "Sizing", .size = 16, .key = .src(@src()) },
        Spacer{ .height = .fixed(8), .key = .src(@src()) },
    });
    // Row 1: grow | fixed(80) | grow
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(24),
            .dir = .row,
            .key = .src(@src()),
        },
        .{
            Rect{
                .width = .grow(),
                .height = .fixed(24),
                .key = .src(@src()),
                .style = .{ .color = .info, .corner_radius = .sm },
            },
            Rect{
                .width = .fixed(80),
                .height = .fixed(24),
                .key = .src(@src()),
                .style = .{ .color = .warning, .corner_radius = .sm },
            },
            Rect{
                .width = .grow(),
                .height = .fixed(24),
                .key = .src(@src()),
                .style = .{ .color = .info, .corner_radius = .sm },
            },
        },
    });

    try app.e(.{Spacer{ .height = .fixed(6), .key = .src(@src()) }});

    // Row 2: 25% | 50% | 25%
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(24),
            .dir = .row,
            .key = .src(@src()),
        },
        .{
            Rect{
                .width = .percent(0.25),
                .height = .fixed(24),
                .key = .src(@src()),
                .style = .{ .color = .secondary, .corner_radius = .sm },
            },
            Rect{
                .width = .percent(0.50),
                .height = .fixed(24),
                .key = .src(@src()),
                .style = .{ .color = .primary, .corner_radius = .sm },
            },
            Rect{
                .width = .percent(0.25),
                .height = .fixed(24),
                .key = .src(@src()),
                .style = .{ .color = .secondary, .corner_radius = .sm },
            },
        },
    });

    try app.e(.{Spacer{ .height = .fixed(6), .key = .src(@src()) }});

    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(24),
            .dir = .row,
            .key = .src(@src()),
        },
        .{
            Rect{
                .width = .fixed(60),
                .height = .fixed(24),
                .key = .src(@src()),
                .style = .{ .color = .warning, .corner_radius = .sm },
            },
            Rect{
                .width = .grow(),
                .height = .fixed(24),
                .key = .src(@src()),
                .style = .{ .color = .success, .corner_radius = .sm },
            },
            Rect{
                .width = .fixed(100),
                .height = .fixed(24),
                .key = .src(@src()),
                .style = .{ .color = .warning, .corner_radius = .sm },
            },
            Rect{
                .width = .grow(),
                .height = .fixed(24),
                .key = .src(@src()),
                .style = .{ .color = .success, .corner_radius = .sm },
            },
        },
    });
}

fn renderSectionNesting(app: *knots.App) !void {
    try app.e(.{
        Text{
            .content = "Nesting",
            .size = 16,
            .key = .src(@src()),
        },
        Spacer{ .height = .fixed(8), .key = .src(@src()) },
        Rect{
            .width = .grow(),
            .height = .fit(),
            .padding = .init(10, 10, 10, 10),
            .key = .src(@src()),
            .style = .{
                .color = .muted,
                .corner_radius = .xl,
                .border_width = 2,
                .border_color = .@"error",
            },
        },
        .{renderNestingLevel1},
    });
}

fn renderSectionAlignment(app: *knots.App) !void {
    try app.e(
        .{
            Text{ .content = "Alignment", .size = 16, .key = .src(@src()) },
            Spacer{ .height = .fixed(8), .key = .src(@src()) },
            Rect{
                .width = .grow(),
                .height = .fixed(100),
                .dir = .row,
                .key = .src(@src()),
            },
            .{
                Rect{
                    .width = .grow(),
                    .height = .fixed(100),
                    .@"align" = .start,
                    .padding = .init(4, 4, 4, 4),
                    .key = .src(@src()),
                    .style = .{
                        .color = .muted,
                        .corner_radius = .sm,
                        .border_width = 1,
                        .border_color = .toned,
                    },
                },
                .{
                    Rect{
                        .width = .fixed(20),
                        .height = .fixed(20),
                        .key = .src(@src()),
                        .style = .{ .color = .@"error", .corner_radius = .sm },
                    },
                    Rect{
                        .width = .fixed(20),
                        .height = .fixed(20),
                        .key = .src(@src()),
                        .style = .{ .color = .@"error", .corner_radius = .sm },
                    },
                    Text{
                        .content = "start",
                        .size = 9,
                        .color = .dimmed,
                        .key = .src(@src()),
                    },
                },
                Spacer{ .width = .fixed(4), .key = .src(@src()) },
                Rect{
                    .width = .grow(),
                    .height = .fixed(100),
                    .@"align" = .center,
                    .padding = .init(4, 4, 4, 4),
                    .key = .src(@src()),
                    .style = .{
                        .color = .muted,
                        .corner_radius = .sm,
                        .border_width = 1,
                        .border_color = .toned,
                    },
                },
                .{
                    Rect{
                        .width = .fixed(20),
                        .height = .fixed(20),
                        .key = .src(@src()),
                        .style = .{ .color = .success, .corner_radius = .sm },
                    },
                    Rect{
                        .width = .fixed(20),
                        .height = .fixed(20),
                        .key = .src(@src()),
                        .style = .{ .color = .success, .corner_radius = .sm },
                    },
                    Text{
                        .content = "center",
                        .size = 9,
                        .color = .dimmed,
                        .key = .src(@src()),
                    },
                },
                Spacer{ .width = .fixed(4), .key = .src(@src()) },
                Rect{
                    .width = .grow(),
                    .height = .fixed(100),
                    .@"align" = .end,
                    .padding = .init(4, 4, 4, 4),
                    .key = .src(@src()),
                    .style = .{
                        .color = .muted,
                        .corner_radius = .sm,
                        .border_width = 1,
                        .border_color = .toned,
                    },
                },
                .{
                    Rect{
                        .width = .fixed(20),
                        .height = .fixed(20),
                        .key = .src(@src()),
                        .style = .{ .color = .primary, .corner_radius = .sm },
                    },
                    Rect{
                        .width = .fixed(20),
                        .height = .fixed(20),
                        .key = .src(@src()),
                        .style = .{ .color = .primary, .corner_radius = .sm },
                    },
                    Text{
                        .content = "end",
                        .size = 9,
                        .color = .dimmed,
                        .key = .src(@src()),
                    },
                },
            },
        },
    );
}

fn renderNestingLevel1(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .padding = .init(10, 10, 10, 10),
            .key = .src(@src()),
            .style = .{
                .color = .muted,
                .corner_radius = .lg,
                .border_width = 2,
                .border_color = .success,
            },
        },
        .{renderNestingLevel2},
    });
}

fn renderNestingLevel2(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .padding = .init(10, 10, 10, 10),
            .key = .src(@src()),
            .style = .{
                .color = .muted,
                .corner_radius = .sm,
                .border_width = 2,
                .border_color = .primary,
            },
        },
        .{renderNestingLevel3},
    });
}

fn renderNestingLevel3(app: *knots.App) !void {
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .padding = .init(8, 8, 8, 8),
            .@"align" = .center,
            .justify = .center,
            .key = .src(@src()),
            .style = .{
                .color = .muted,
                .corner_radius = .none,
                .border_width = 2,
                .border_color = .warning,
            },
        },
        .{
            Text{
                .content = "innermost",
                .size = 11,
                .color = .warning,
                .key = .src(@src()),
            },
        },
    });
}

fn renderSectionControlFlow(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);

    try app.e(.{
        Text{ .content = "Control Flow", .size = 16, .key = .src(@src()) },
        Spacer{ .height = .fixed(8), .key = .src(@src()) },
        Rect{
            .width = .grow(),
            .height = .fit(),
            .dir = .column,
            .gap = 8,
            .key = .src(@src()),
        },
        .{
            Rect{
                .width = .grow(),
                .height = .fit(),
                .dir = .row,
                .@"align" = .center,
                .gap = 8,
                .key = .src(@src()),
            },
            .{
                Button{
                    .height = .fixed(30),
                    .width = .fixed(80),
                    .style = .{ .color = .primary, .corner_radius = .sm },
                    .key = .src(@src()),
                    .onClick = toggleDetails,
                    .justify = .center,
                    .@"align" = .center,
                    .text = .{ .content = if (self.show_details) "hide" else "show" },
                },
            },
            renderDetailsAnimated,
        },
    });
}

const details_measure_key: knots.ui.Key = .str("details.measure");
const details_tween_key: knots.ui.Key = .str("details.tween");
const details_visible_clip_key: knots.ui.Key = .str("details.visible");

fn renderDetails(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fit(),
            .padding = .init(8, 8, 8, 8),
            .key = .src(@src()),
            .style = .{ .color = .info, .corner_radius = .sm },
            .dir = .column,
            .gap = 2,
        },
        .{
            For(isize){
                .items = self.counter_items.items,
                .each = renderCounterItem,
            },
        },
    });
}

fn renderDetailsMeasured(app: *knots.App) !void {
    try app.e(animation.Measure{
        .key = details_measure_key,
        .width = .grow(),
        .height = .fit(),
        .child = renderDetails,
    });
}

fn isPositive(v: f32) bool {
    return v > 0.5;
}

fn renderDetailsAnimated(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);

    const measure = animation.Measure{
        .key = details_measure_key,
        .width = .grow(),
        .height = .fit(),
        .child = renderDetails,
    };

    const target: f32 = if (self.show_details) measure.readHeight(app) else 0.0;

    const tween = animation.Animated(f32){
        .key = details_tween_key,
        .target = target,
        .duration_ms = 250,
        .ease = .ease_out_cubic,
    };
    const h = tween.read(app);
    self.details_tween_h = h;

    try app.e(animation.Clip{
        .key = details_visible_clip_key,
        .width = .grow(),
        .height = .fixed(h),
        .child = renderDetailsGated,
    });
}

fn renderDetailsGated(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try app.e(animation.When{
        .active = self.show_details,
        .value = self.details_tween_h,
        .visible = isPositive,
        .then = renderDetailsMeasured,
    });
}

fn renderSectionInputs(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    try app.e(.{
        Text{ .content = "Input", .size = 16, .key = .src(@src()) },
        Spacer{ .height = .fixed(8), .key = .src(@src()) },
        TextInput{
            .key = .src(@src()),
            .buf = &self.name_buf,
            .placeholder = "Start typing...",
        },
        Spacer{ .height = .fixed(8), .key = .src(@src()) },
        SelectInput(Fruit){ .key = .src(@src()) },
    });
}

fn renderCounterItem(app: *knots.App, item: isize, i: usize) !void {
    const arena = app.arena();
    try app.e(.{
        Rect{
            .width = .grow(),
            .height = .fixed(24),
            .padding = .init(4, 8, 4, 8),
            .key = knots.ui.Key.src(@src()).indexed(i),
            .style = .{ .color = .muted, .corner_radius = .sm },
        },
        .{Text{
            .content = try std.fmt.allocPrint(arena, "item {d}", .{item}),
            .size = 11,
            .key = knots.ui.Key.src(@src()).indexed(i),
        }},
    });
}

fn toggleDetails(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.show_details = !self.show_details;
}

fn renderGrid(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);

    try app.e(.{
        Canvas{
            .width = .grow(),
            .height = .grow(),
            .onDraw = drawGrid,
            .cmds = &self.grid_cmds,
            .key = .src(@src()),
        },
    });
}

fn drawGrid(app: *knots.App, painter: *Canvas.Painter) !void {
    const size = app.window.getSize();
    const w: f32 = @floatFromInt(size.width);
    const h: f32 = @floatFromInt(size.height);
    const t = @as(f32, @floatFromInt(@mod(app.timer.ms(), 10000))) / 10000.0;
    const n = 16;

    for (0..n) |i| {
        for (0..n) |j| {
            const fi: f32 = @floatFromInt(i);
            const fj: f32 = @floatFromInt(j);
            const fn_: f32 = @floatFromInt(n);
            const cell_w = w / fn_;
            const cell_h = h / fn_;

            const hue_tl = @mod((fi / fn_) * 0.75 + (fj / fn_) * 0.57 + t, 1.0);
            const hue_tr = @mod((fi / fn_) * 0.75 + ((fj + 1) / fn_) * 0.57 + t, 1.0);
            const hue_br = @mod(((fi + 1) / fn_) * 0.75 + ((fj + 1) / fn_) * 0.57 + t, 1.0);
            const hue_bl = @mod(((fi + 1) / fn_) * 0.75 + (fj / fn_) * 0.57 + t, 1.0);

            try painter.fillRectGradient(.{
                .x = fj * cell_w,
                .y = fi * cell_h,
                .w = cell_w,
                .h = cell_h,
                .colors = .{
                    hsvToRgb(hue_tl, 0.75, 0.85),
                    hsvToRgb(hue_tr, 0.75, 0.85),
                    hsvToRgb(hue_br, 0.75, 0.85),
                    hsvToRgb(hue_bl, 0.75, 0.85),
                },
            });
        }
    }

    try app.signal(.redraw);
}

fn increment(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.cntr += 1;
    try self.counter_items.append(self.allocator, self.cntr);
}

fn decrement(app: *knots.App) !void {
    const self: *Self = @fieldParentPtr("app", app);
    self.cntr -= 1;
    _ = self.counter_items.pop();
}

fn exit(app: *knots.App) !void {
    try app.signal(.exit);
}

fn sleep(app: *knots.App) !void {
    if (is_emscripten) {
        for (0..50) |_| try increment(app);
        return;
    }

    const self: *Self = @fieldParentPtr("app", app);
    for (0..50) |i| {
        try app.dispatch(
            sleepHello,
            .{ self.io, try std.fmt.allocPrint(self.allocator, "Hello, World! ({d})", .{i}) },
            onWakeupHello,
        );
    }
}

fn sleepHello(io: std.Io, msg: []const u8) std.Io.Cancelable![]const u8 {
    try io.sleep(.fromSeconds(2), .boot);
    return msg;
}

fn onWakeupHello(app: *knots.App, res: std.Io.Cancelable![]const u8) !void {
    const self: *Self = @fieldParentPtr("app", app);
    const msg = try res;
    defer self.allocator.free(msg);
    std.log.info("Woke up at {d}ms! Message: {s}", .{ app.timer.ms(), msg });
    try increment(app);
}

fn srgbToLinear(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

fn hsvToRgb(h: f32, s: f32, v: f32) [4]f32 {
    const h6 = h * 6.0;
    const i = @as(u32, @intFromFloat(@floor(h6))) % 6;
    const f = h6 - @floor(h6);
    const p = v * (1.0 - s);
    const q = v * (1.0 - s * f);
    const t = v * (1.0 - s * (1.0 - f));
    const srgb: [3]f32 = switch (i) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
    return .{ srgbToLinear(srgb[0]), srgbToLinear(srgb[1]), srgbToLinear(srgb[2]), 1.0 };
}
