const std = @import("std");
const knots = @import("knots");
const capture_utils = @import("Capture.zig");
const qoi = @import("qoi.zig");

const Rect = knots.component.Rect;
const Text = knots.component.Text;
const Button = knots.component.Button;
const Checkbox = knots.component.Checkbox;
const SliderInput = knots.component.SliderInput;
const ProgressBar = knots.component.ProgressBar;
const Canvas = knots.component.Canvas;
const Image = knots.component.Image;
const Spacer = knots.component.Spacer;
const Dialog = knots.component.Dialog;

const WIDTH = 800;
const HEIGHT = 600;
const MAX_CHANNEL_DELTA = 2;
const scene_names = [_][]const u8{ "layout", "components", "graphics", "overlay" };

io: std.Io,
allocator: std.mem.Allocator,
app: knots.App,
backend: []const u8,
update: bool,
failures: usize = 0,
scene: usize = 0,
checked: bool = true,
slider: f32 = 0.64,
dialog_open: bool = true,

const Runner = @This();

pub fn init(io: std.Io, allocator: std.mem.Allocator, backend: []const u8, update: bool) !Runner {
    return .{
        .io = io,
        .allocator = allocator,
        .backend = backend,
        .update = update,
        .app = try .init(io, allocator, .{
            .window = .{ .width = WIDTH, .height = HEIGHT, .title = "Knots snapshots", .resizable = false },
            .renderer = .{ .present_mode = .fifo, .clear_color = .{ 0.035, 0.043, 0.059, 1 } },
        }),
    };
}

pub fn deinit(self: *Runner) void {
    self.app.deinit();
}

pub fn start(self: *Runner) !void {
    try std.Io.Dir.cwd().deleteTree(self.io, "zig-out/snapshot-diffs");
    try self.app.start(frame);
    if (self.failures != 0) {
        std.log.err("{} rendering snapshot(s) failed", .{self.failures});
        return error.SnapshotMismatch;
    }
}

fn frame(app: *knots.App) !void {
    const self: *Runner = @fieldParentPtr("app", app);
    if (app.renderer.takeReadback()) |completed| {
        var readback = completed;
        defer readback.deinit();
        var capture = try capture_utils.fromReadback(self.allocator, readback);
        defer capture.deinit();
        if (!try self.check(scene_names[self.scene], capture)) self.failures += 1;
        self.scene += 1;
        if (self.scene == scene_names.len) {
            try app.signal(.exit);
            return;
        }
    }

    app.ui.content_scale = 1.0;
    switch (self.scene) {
        0 => try renderLayout(app),
        1 => try self.renderComponents(app),
        2 => try renderGraphics(app),
        3 => try self.renderOverlay(app),
        else => unreachable,
    }
    try app.renderer.requestReadback(self.allocator);
    try app.signal(.redraw);
}

fn check(self: *Runner, name: []const u8, capture: capture_utils.Frame) !bool {
    if (capture.width != WIDTH or capture.height != HEIGHT) {
        std.log.err("snapshot '{s}' was {}x{}, expected {}x{}", .{ name, capture.width, capture.height, WIDTH, HEIGHT });
        return false;
    }

    const baseline_path = try std.fmt.allocPrint(self.allocator, "tests/snapshots/{s}/{s}.qoi", .{ self.backend, name });
    defer self.allocator.free(baseline_path);
    if (self.update) {
        try ensureBaselineDirs(self.io, self.allocator, self.backend);
        try writeQoi(self.io, self.allocator, baseline_path, capture.width, capture.height, capture.rgba);
        return true;
    }

    const cwd = std.Io.Dir.cwd();
    const baseline_data = cwd.readFileAlloc(self.io, baseline_path, self.allocator, .limited(64 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            std.log.err("missing snapshot '{s}'; run: zig build update-snapshots -Dgpu_backend={s}", .{ baseline_path, self.backend });
            return false;
        }
        return err;
    };
    defer self.allocator.free(baseline_data);
    var baseline = try qoi.decode(self.allocator, baseline_data);
    defer baseline.deinit(self.allocator);

    const dimensions_match = baseline.width == capture.width and baseline.height == capture.height;
    const diff = try self.allocator.alloc(u8, capture.rgba.len);
    defer self.allocator.free(diff);
    @memset(diff, 0);
    var alpha: usize = 3;
    while (alpha < diff.len) : (alpha += 4) diff[alpha] = 255;
    var changed_pixels: usize = 0;
    var max_delta: u8 = 0;
    var alpha_differs = false;
    if (dimensions_match) {
        var pixel: usize = 0;
        while (pixel < capture.rgba.len) : (pixel += 4) {
            const actual_alpha = capture.rgba[pixel + 3];
            const expected_alpha = baseline.rgba[pixel + 3];
            const alpha_delta = if (actual_alpha > expected_alpha) actual_alpha - expected_alpha else expected_alpha - actual_alpha;
            alpha_differs = alpha_differs or alpha_delta != 0;
            max_delta = @max(max_delta, alpha_delta);
            var changed = alpha_delta != 0;
            for (0..3) |channel| {
                const actual = capture.rgba[pixel + channel];
                const expected = baseline.rgba[pixel + channel];
                const delta = if (actual > expected) actual - expected else expected - actual;
                max_delta = @max(max_delta, delta);
                diff[pixel + channel] = @intCast(@min(255, @as(u16, delta) * 16));
                changed = changed or delta > MAX_CHANNEL_DELTA;
            }
            diff[pixel + 3] = 255;
            if (changed) changed_pixels += 1;
        }
    }
    const pixel_count = @as(usize, capture.width) * @as(usize, capture.height);
    const allowed_changed_pixels = (pixel_count + 1999) / 2000;
    if (dimensions_match and !alpha_differs and changed_pixels <= allowed_changed_pixels) return true;

    try ensureDiffDir(self.io);
    const actual_path = try std.fmt.allocPrint(self.allocator, "zig-out/snapshot-diffs/{s}-{s}-actual.qoi", .{ self.backend, name });
    defer self.allocator.free(actual_path);
    const diff_path = try std.fmt.allocPrint(self.allocator, "zig-out/snapshot-diffs/{s}-{s}-diff.qoi", .{ self.backend, name });
    defer self.allocator.free(diff_path);
    try writeQoi(self.io, self.allocator, actual_path, capture.width, capture.height, capture.rgba);
    try writeQoi(self.io, self.allocator, diff_path, capture.width, capture.height, diff);
    if (dimensions_match) {
        const percent = @as(f64, @floatFromInt(changed_pixels)) * 100.0 / @as(f64, @floatFromInt(pixel_count));
        std.log.err("snapshot '{s}' differs: {} changed pixels ({d:.4}%, {} allowed), maximum channel delta {}; actual and diff written under zig-out/snapshot-diffs", .{ name, changed_pixels, percent, allowed_changed_pixels, max_delta });
    } else {
        std.log.err("snapshot '{s}' dimensions differ; actual and diff written under zig-out/snapshot-diffs", .{name});
    }
    return false;
}

fn renderComponents(self: *Runner, app: *knots.App) !void {
    const hovered = knots.ui.Key.str("component-primary").hash();
    app.ui.state.hovered = hovered;
    app.ui.state.focused = knots.ui.Key.str("component-checkbox").hash();
    const scroll = try app.ui.state.getOrCreate(.scroll, app.ui.allocator, knots.ui.Key.str("component-scroll").hash());
    scroll.offset[1] = 30;
    try app.e(.{
        page(),
        .{
            Text{ .content = "Interactive controls in deterministic hovered, focused, and selected states.", .size = .sm, .color = .dimmed, .key = .str("component-copy") },
            Spacer{ .height = .fixed(18), .key = .str("component-space-1") },
            Rect{ .width = .grow(), .height = .fixed(54), .dir = .row, .gap = 12, .key = .str("button-row") },
            .{
                Button{ .key = .str("component-primary"), .width = .fixed(150), .height = .fixed(42), .padding = .init(8, 16, 8, 16), .@"align" = .center, .justify = .center, .style = .{ .color = .primary, .corner_radius = .md }, .text = .{ .content = "Hovered button" } },
                Button{ .key = .str("component-disabled"), .width = .fixed(150), .height = .fixed(42), .padding = .init(8, 16, 8, 16), .@"align" = .center, .justify = .center, .disabled = true, .style = .{ .color = .muted, .corner_radius = .md }, .text = .{ .content = "Disabled" } },
            },
            Spacer{ .height = .fixed(18), .key = .str("component-space-2") },
            Checkbox{ .checked = &self.checked, .label = "Focused checked option", .key = .str("component-checkbox") },
            Spacer{ .height = .fixed(22), .key = .str("component-space-3") },
            SliderInput{ .value = &self.slider, .width = .fixed(420), .key = .str("component-slider") },
            Spacer{ .height = .fixed(20), .key = .str("component-space-4") },
            ProgressBar{ .progress = 0.72, .width = .fixed(420), .height = .fixed(12), .key = .str("component-progress") },
            Spacer{ .height = .fixed(18), .key = .str("component-space-5") },
            Rect{ .width = .fixed(420), .height = .fixed(100), .padding = .init(8, 10, 8, 10), .dir = .column, .gap = 8, .overflow = .scroll_y, .style = .{ .color = .muted, .corner_radius = .md }, .key = .str("component-scroll") },
            .{
                Text{ .content = "Scrolled content row one", .key = .str("scroll-row-1") },
                Text{ .content = "Scrolled content row two", .key = .str("scroll-row-2") },
                Text{ .content = "Scrolled content row three", .key = .str("scroll-row-3") },
                Text{ .content = "Scrolled content row four", .key = .str("scroll-row-4") },
                Text{ .content = "Scrolled content row five", .key = .str("scroll-row-5") },
                Text{ .content = "Scrolled content row six", .key = .str("scroll-row-6") },
            },
        },
    });
}

fn renderOverlay(self: *Runner, app: *knots.App) !void {
    try app.e(.{
        page(),
        .{
            Text{ .content = "Modal layering", .size = .xl, .key = .str("overlay-title") },
            Text{ .content = "The dialog verifies root layers, backdrop blending, input scopes, and nested panel layout.", .width = .fixed(560), .wrap = true, .color = .dimmed, .key = .str("overlay-copy") },
        },
        Dialog{ .is_open = &self.dialog_open, .width = .fixed(430), .padding = .init(24, 24, 24, 24), .gap = 14, .key = .str("overlay-dialog") },
        .{
            Text{ .content = "Snapshot dialog", .size = .lg, .key = .str("dialog-title") },
            Text{ .content = "A deterministic open overlay rendered above the underlying scene.", .width = .fixed(360), .wrap = true, .color = .dimmed, .key = .str("dialog-copy") },
            Button{ .key = .str("dialog-action"), .width = .fixed(140), .height = .fixed(38), .@"align" = .center, .justify = .center, .style = .{ .color = .primary, .corner_radius = .md }, .text = .{ .content = "Confirm" } },
        },
    });
}

fn page() Rect {
    return .{
        .width = .fixed(WIDTH),
        .height = .fixed(HEIGHT),
        .padding = .init(28, 32, 28, 32),
        .dir = .column,
        .gap = 6,
        .style = .{ .color = .bg, .corner_radius = .none },
        .key = .str("page"),
    };
}

fn swatch(key: []const u8, color: knots.ui.Color.Input, radius: knots.ui.Radius.Input, width: f32) Rect {
    return .{ .width = .fixed(width), .height = .fixed(72), .style = .{ .color = color, .corner_radius = radius }, .key = .str(key) };
}

const checker = makeChecker();

fn makeChecker() [16 * 16 * 4]u8 {
    var pixels: [16 * 16 * 4]u8 = undefined;
    for (0..16) |y| for (0..16) |x| {
        const i = (y * 16 + x) * 4;
        const bright: u8 = if (((x / 4) + (y / 4)) % 2 == 0) 235 else 55;
        pixels[i..][0..4].* = .{ bright, if (bright > 100) 90 else 190, 210, 255 };
    };
    return pixels;
}

fn renderGraphics(app: *knots.App) !void {
    try app.e(.{
        page(),
        .{
            Text{ .content = "Canvas, images, and layers", .size = .xl, .key = .str("graphics-title") },
            Spacer{ .height = .fixed(18), .key = .str("graphics-space") },
            Rect{ .width = .grow(), .height = .fixed(250), .dir = .row, .gap = 24, .key = .str("graphics-row") },
            .{
                Canvas{ .width = .fixed(340), .height = .fixed(230), .style = .{ .color = .muted, .corner_radius = .lg, .border_width = .all(1), .border_color = .toned }, .onDraw = drawCanvas, .key = .str("graphics-canvas") },
                Rect{ .width = .fixed(230), .height = .fixed(230), .dir = .column, .gap = 16, .key = .str("graphics-side") },
                .{
                    Image{ .source = .{ .pixels = .{ .data = &checker, .width = 16, .height = 16, .upload_policy = .versioned } }, .width = .fixed(150), .height = .fixed(100), .key = .str("graphics-image") },
                    Rect{ .width = .fixed(180), .height = .fixed(90), .dir = .layer, .key = .str("graphics-layer") },
                    .{
                        Rect{ .width = .fixed(120), .height = .fixed(80), .style = .{ .color = .secondary, .corner_radius = .lg }, .key = .str("layer-back") },
                        Rect{ .width = .fixed(80), .height = .fixed(54), .style = .{ .color = .warning, .corner_radius = .{ .fixed = 27 } }, .key = .str("layer-front") },
                    },
                },
            },
        },
    });
}

fn drawCanvas(_: *knots.App, painter: *Canvas.Painter) !void {
    try painter.fillRectGradient(.{ .x = 18, .y = 18, .w = 304, .h = 70, .corner_radius = .all(14), .colors = .{ .{ 0.28, 0.36, 0.95, 1 }, .{ 0.70, 0.28, 0.92, 1 }, .{ 0.95, 0.35, 0.48, 1 }, .{ 0.25, 0.75, 0.90, 1 } } });
    try painter.fillCircle(.{ .cx = 82, .cy = 155, .radius = 42, .color = .{ 0.2, 0.75, 0.52, 1 } });
    try painter.strokeCircle(.{ .cx = 170, .cy = 155, .radius = 42, .thickness = 7, .color = .{ 0.95, 0.72, 0.18, 1 } });
    try painter.fillTriangle(.{ .points = .{ .{ 240, 196 }, .{ 292, 112 }, .{ 322, 196 } }, .color = .{ 0.92, 0.3, 0.38, 1 } });
    try painter.line(.{ .from = .{ 25, 216 }, .to = .{ 315, 216 }, .thickness = 3, .color = .{ 0.75, 0.8, 0.9, 1 } });
}

fn ensureDiffDir(io: std.Io) !void {
    try makeDir(io, "zig-out");
    try makeDir(io, "zig-out/snapshot-diffs");
}

fn makeDir(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

fn writeQoi(io: std.Io, allocator: std.mem.Allocator, path: []const u8, width: u32, height: u32, rgba: []const u8) !void {
    const encoded = try qoi.encode(allocator, width, height, rgba);
    defer allocator.free(encoded);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = encoded });
}

fn ensureBaselineDirs(io: std.Io, allocator: std.mem.Allocator, backend: []const u8) !void {
    try makeDir(io, "tests");
    try makeDir(io, "tests/snapshots");
    const path = try std.fmt.allocPrint(allocator, "tests/snapshots/{s}", .{backend});
    defer allocator.free(path);
    try makeDir(io, path);
}

fn renderLayout(app: *knots.App) !void {
    try app.e(.{
        page(),
        .{
            Text{ .content = "Layout, text, and clipping", .size = .xl, .key = .str("layout-title") },
            Text{ .content = "One frame covers sizing, alignment, wrapping, borders, radii, nested clipping, and primitive batching.", .width = .fixed(600), .wrap = true, .size = .sm, .color = .dimmed, .key = .str("layout-copy") },
            Spacer{ .height = .fixed(20), .key = .str("layout-space-1") },
            Rect{ .width = .grow(), .height = .fixed(96), .dir = .row, .gap = 14, .key = .str("layout-row") },
            .{
                swatch("layout-a", .primary, .sm, 110),
                swatch("layout-b", .secondary, .lg, 170),
                swatch("layout-c", .warning, .xl, 80),
                Rect{ .width = .grow(), .height = .fixed(72), .style = .{ .color = .success, .corner_radius = .md, .border_width = .all(3), .border_color = .toned }, .key = .str("layout-grow") },
            },
            Spacer{ .height = .fixed(24), .key = .str("layout-space-2") },
            Rect{ .width = .fixed(460), .height = .fixed(170), .padding = .init(14, 14, 14, 14), .overflow = .hidden, .style = .{ .color = .muted, .corner_radius = .xl, .border_width = .all(2), .border_color = .primary }, .key = .str("clip-outer") },
            .{
                Rect{ .width = .fixed(620), .height = .fixed(80), .padding = .init(12, 18, 12, 18), .style = .{ .color = .accented, .corner_radius = .lg }, .key = .str("clip-wide") },
                .{Text{ .content = "This oversized child and its text are clipped by a rounded parent.", .size = .md, .key = .str("clip-text") }},
                Rect{ .width = .fixed(390), .height = .fixed(48), .style = .{ .color = .info, .corner_radius = .{ .fixed = 24 } }, .key = .str("clip-pill") },
            },
        },
    });
}
