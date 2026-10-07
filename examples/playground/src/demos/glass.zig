const std = @import("std");
const knots = @import("knots");
const ui = @import("knots-ui");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const Canvas = ui.component.Canvas;
const SelectInput = ui.component.SelectInput;
const SliderInput = ui.component.SliderInput;
const Spacer = ui.component.Spacer;
const Key = ui.Key;

const Preset = enum { glass, frosted };

const stage_width = 720;
const stage_height = 460;

var preset: u32 = 0;
var material: ui.Material = .glass;

const white_tint: ui.Color.Input = .{ .color = ui.Color.rgba(255, 255, 255, 22) };
const ink: ui.Color.Input = .{ .color = ui.Color.rgba(16, 20, 28, 255) };

pub fn render(_: *knots.App, app: *ui.Frame) !void {
    const row = Rect{ .key = .src(@src()), .style = &.{ .direction = .row, .gap = 20 } };
    _ = try row.open(app);
    try controls(app);
    try stage(app);
    try row.close(app);
    // The background animates.
    app.requestRedraw();
}

fn controls(app: *ui.Frame) !void {
    const column = Rect{ .key = .src(@src()), .style = &.{ .width = .fixed(220), .direction = .column, .gap = 10 } };
    _ = try column.open(app);
    const selection = try app.interact(SelectInput(Preset){ .key = .src(@src()), .initial_selected = preset });
    if (selection.selected) |selected| {
        preset = selected.index;
        material = switch (@as(Preset, @fromBackingInt(@intCast(preset)))) {
            .glass => .glass,
            .frosted => .frosted,
        };
    }
    try app.e(Spacer{ .key = .src(@src()), .style = &.{ .height = .fixed(4) } });
    try slider(app, "blur", &material.blur, 40, .src(@src()));
    try slider(app, "saturation", &material.saturation, 2, .src(@src()));
    try slider(app, "refraction", &material.refraction, 40, .src(@src()));
    try slider(app, "bezel", &material.bezel, 60, .src(@src()));
    try slider(app, "dispersion", &material.dispersion, 1, .src(@src()));
    try slider(app, "specular", &material.specular, 1, .src(@src()));
    try app.e(Text{
        .content = "Style.backdrop filters what is painted behind an element; background tints it.",
        .key = .src(@src()),
        .style = &.{ .font_size = .xs, .foreground = .dimmed, .wrap = true, .width = .grow() },
    });
    try column.close(app);
}

fn slider(app: *ui.Frame, label: []const u8, value: *f32, max: f32, key: Key) !void {
    const field = Rect{ .key = key, .style = &.{ .width = .grow(), .direction = .column, .gap = 4 } };
    _ = try field.open(app);
    try app.e(Text{
        .content = try std.fmt.allocPrint(app.arena(), "{s}: {d:.2}", .{ label, value.* }),
        .key = key.indexed(1),
        .style = &.{ .font_size = .xs, .foreground = .dimmed },
    });
    const track = Rect{ .key = key.indexed(2), .style = &.{ .width = .grow(), .height = .fixed(20), .padding = .init(8, 0, 8, 0) } };
    _ = try track.open(app);
    _ = try app.interact(SliderInput{ .key = key.indexed(3), .value = value, .max = max });
    try track.close(app);
    try field.close(app);
}

fn stage(app: *ui.Frame) !void {
    const t = @as(f32, @floatFromInt(@mod(app.input().now_ms, 60_000))) / 1000.0;

    var commands: std.ArrayList(Canvas.DrawCmd) = .empty;
    var painter = Canvas.Painter{ .cmds = &commands, .allocator = app.arena() };
    try drawBackground(&painter, t);

    const root = Rect{ .key = .src(@src()), .style = &.{
        .width = .fixed(stage_width),
        .height = .fixed(stage_height),
        .direction = .layer,
        .radius = .lg,
        .overflow = .hidden,
    } };
    _ = try root.open(app);
    try app.e(Canvas{
        .commands = commands.items,
        .key = .src(@src()),
        .style = &.{ .width = .fixed(stage_width), .height = .fixed(stage_height) },
    });

    // A card using the material from the controls.
    try app.e(.{
        Rect{ .key = .src(@src()), .style = &.{
            .width = .fixed(320),
            .position = .absolute,
            .offset = .{ 36, 36 },
            .direction = .column,
            .gap = 8,
            .padding = .all(24),
            .radius = .{ .fixed = 28 },
            .backdrop = material,
            .background = white_tint,
        } },
        .{
            Text{ .content = "Backdrop refraction", .key = .src(@src()), .style = &.{ .font_size = .xl, .foreground = ink } },
            Text{
                .content = "Blur, saturation, refraction, dispersion and a rim highlight, all from one style field.",
                .key = .src(@src()),
                .style = &.{ .wrap = true, .width = .grow(), .font_size = .sm, .foreground = ink },
            },
        },
    });

    // Frosted pills that turn to glass on hover, animated by the style transition.
    const pills = Rect{ .key = .src(@src()), .style = &.{ .position = .absolute, .offset = .{ 36, 370 }, .direction = .row, .gap = 12 } };
    _ = try pills.open(app);
    inline for (.{ "Library", "For you", "Search" }, 0..) |label, index| {
        _ = try app.interact(Button{
            .key = Key.src(@src()).indexed(index),
            .label = label,
            .style = &.{
                .height = .fixed(44),
                .padding = .xy(22, 0),
                .radius = .{ .fixed = 22 },
                .backdrop = .frosted,
                .background = white_tint,
                .foreground = ink,
                .hover = &.{ .backdrop = .glass, .state_layer = 0 },
                .active = &.{ .state_layer = 0.1 },
                .transition = .{ .duration_ms = 220 },
            },
        });
    }
    try pills.close(app);

    // A clear lens drifting over the scene.
    try app.e(Rect{ .key = .src(@src()), .style = &.{
        .width = .fixed(150),
        .height = .fixed(150),
        .position = .absolute,
        .offset = .{ 470 + 90 * @cos(t * 0.6), 150 + 90 * @sin(t * 0.8) },
        .radius = .{ .fixed = 75 },
        .backdrop = .{ .refraction = 26, .bezel = 50, .dispersion = 0.3, .specular = 0.8 },
    } });
    try root.close(app);
}

fn drawBackground(painter: *Canvas.Painter, t: f32) !void {
    const w: f32 = stage_width;
    const h: f32 = stage_height;
    try painter.fillRectGradient(.{ .x = 0, .y = 0, .w = w, .h = h, .colors = .{
        .{ 0.10, 0.12, 0.30, 1 },
        .{ 0.35, 0.10, 0.40, 1 },
        .{ 0.05, 0.35, 0.45, 1 },
        .{ 0.12, 0.20, 0.35, 1 },
    } });

    // Stripes show refraction clearly.
    var x: f32 = 0;
    while (x < w) : (x += 36) {
        try painter.fillRect(.{ .x = x, .y = 0, .w = 12, .h = h, .color = .{ 1, 1, 1, 0.08 } });
    }

    const blobs = [_]struct { color: [4]f32, radius: f32, speed: f32, phase: f32 }{
        .{ .color = .{ 1.0, 0.45, 0.35, 1 }, .radius = 90, .speed = 0.35, .phase = 0 },
        .{ .color = .{ 1.0, 0.80, 0.25, 1 }, .radius = 70, .speed = 0.5, .phase = 1.7 },
        .{ .color = .{ 0.35, 0.85, 0.60, 1 }, .radius = 80, .speed = 0.42, .phase = 3.1 },
        .{ .color = .{ 0.40, 0.60, 1.00, 1 }, .radius = 100, .speed = 0.28, .phase = 4.4 },
        .{ .color = .{ 0.95, 0.40, 0.85, 1 }, .radius = 60, .speed = 0.6, .phase = 5.6 },
    };
    for (blobs) |blob| {
        const angle = t * blob.speed + blob.phase;
        try painter.fillCircle(.{
            .cx = w * 0.5 + (w * 0.33) * @cos(angle),
            .cy = h * 0.5 + (h * 0.3) * @sin(angle * 1.3),
            .radius = blob.radius,
            .color = blob.color,
        });
    }
}
