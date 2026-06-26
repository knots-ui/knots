const std = @import("std");

const App = @import("knots").App;
const Element = @import("layout").Element;
const ui_mod = @import("ui");

const Color = ui_mod.Color;
const Decoration = ui_mod.Decoration;
const Key = ui_mod.Key;
const Size = ui_mod.Size;
const State = ui_mod.State;
const Style = ui_mod.Style;

value: *Color,
key: Key,
onChange: ?*const fn (*App) anyerror!void = null,

width: Element.sizing.Axis = .fixed(180),
height: Element.sizing.Axis = .fit(),
size: Size.Input = .sm,
style: Style = .{ .color = .muted, .corner_radius = .sm, .border_color = .toned, .border_width = .all(1) },
focused_style: Style = .{ .color = .elevated, .corner_radius = .sm, .border_color = .primary, .border_width = .all(1) },
popover_style: Style = .{ .color = .elevated, .corner_radius = .md, .border_color = .toned, .border_width = .all(1) },
text_color: Color.Input = .text,
swatch_size: f32 = 18,
popover_width: f32 = 240,
sv_height: f32 = 150,
strip_height: f32 = 16,

const ColorPicker = @This();

const SWATCH_INDEX: usize = 1;
const TEXT_INDEX: usize = 2;
const POPUP_INDEX: usize = 3;
const SV_INDEX: usize = 4;
const HUE_INDEX: usize = 5;
const ALPHA_INDEX: usize = 6;
const PREVIEW_INDEX: usize = 7;
const HEX_INDEX: usize = 8;

pub fn open(self: *const ColorPicker, app: *App) !Element.Id {
    const ui = &app.ui;
    const id = self.key.hash();
    const s = try ui.state.getOrCreate(.color_picker, ui.allocator, id);

    syncStateFromColor(s, self.value.*);

    if (ui.leftClicked(id)) {
        s.open = !s.open;
        s.editing_hex = false;
        if (s.open) {
            s.original_color = self.value.value;
            s.has_original = true;
        } else {
            s.has_original = false;
        }
    }

    if (s.open) {
        try handlePickerInput(self, app, s);
        if (ui.input.mouseButton(.left).pressed and !self.isPointerInside(app, s)) {
            s.open = false;
            s.editing_hex = false;
            s.has_original = false;
        }
    }

    var h = self.height;
    h.min = @max(self.swatch_size + 8, try ui.lineHeight(self.size.resolve(), null) + 8);

    const current_style = if (s.open or ui.focused(id)) self.focused_style else self.style;
    return try ui.open(self.key, .{
        .width = self.width,
        .height = h,
        .direction = .row,
        .alignment = .center,
        .gap = 8,
        .padding = .init(4, 8, 4, 8),
        .interactive = true,
    }, .{ .rect = current_style.toRect(&ui.theme) });
}

pub fn close(self: *const ColorPicker, app: *App) !void {
    const ui = &app.ui;
    const id = self.key.hash();
    const s = try ui.state.getOrCreate(.color_picker, ui.allocator, id);

    var swatch_cmds: std.ArrayList(Decoration.DrawCmd) = .empty;
    const arena = app.arena();
    try appendCheckerboard(&swatch_cmds, arena, self.swatch_size, self.swatch_size, 6);
    try swatch_cmds.append(arena, .{ .fill_rect = .{
        .x = 0,
        .y = 0,
        .w = self.swatch_size,
        .h = self.swatch_size,
        .color = self.value.value,
        .corner_radius = .all(3),
    } });
    try swatch_cmds.append(arena, .{ .stroke_rect = .{
        .x = 0.5,
        .y = 0.5,
        .w = self.swatch_size - 1,
        .h = self.swatch_size - 1,
        .color = .{ 0, 0, 0, 0.35 },
        .corner_radius = .all(2.5),
        .thickness = 1,
    } });
    _ = try ui.open(self.key.indexed(SWATCH_INDEX), .{
        .width = .fixed(self.swatch_size),
        .height = .fixed(self.swatch_size),
    }, .{ .canvas = .{ .cmds = swatch_cmds.items } });
    ui.close();

    {
        const hex = try formatHexAlloc(app.arena(), self.value.*, true);
        var deco = try ui.textDecoration(hex, self.size.resolve(), null, false);
        deco.text.color = self.text_color.resolve(&ui.theme);
        _ = try ui.open(self.key.indexed(TEXT_INDEX), .{ .width = .fit(), .height = .fit() }, deco);
        ui.close();
    }

    ui.close();

    if (s.open) try self.renderPopover(app, s);
}

fn handlePickerInput(self: *const ColorPicker, app: *App, s: *State.ColorPicker) !void {
    const ui = &app.ui;
    const sv_id = self.key.indexed(SV_INDEX).hash();
    const hue_id = self.key.indexed(HUE_INDEX).hash();
    const alpha_id = self.key.indexed(ALPHA_INDEX).hash();
    const hex_id = self.key.indexed(HEX_INDEX).hash();

    if (ui.pressing(sv_id) and ui.input.mouseButton(.left).down) {
        if (ui.state.get(.measured, sv_id)) |m| {
            const p = pointInBox(m, ui.input.mouse_pos);
            s.saturation = p[0];
            s.value = 1.0 - p[1];
            try setColorFromState(self, app, s);
        }
    }

    if (ui.pressing(hue_id) and ui.input.mouseButton(.left).down) {
        if (ui.state.get(.measured, hue_id)) |m| {
            s.hue = pointInBox(m, ui.input.mouse_pos)[0];
            try setColorFromState(self, app, s);
        }
    }

    if (ui.pressing(alpha_id) and ui.input.mouseButton(.left).down) {
        if (ui.state.get(.measured, alpha_id)) |m| {
            s.alpha = pointInBox(m, ui.input.mouse_pos)[0];
            try setColorFromState(self, app, s);
        }
    }

    const hex_focused = ui.focused(hex_id);
    if (hex_focused and !s.editing_hex) {
        var buf: [10]u8 = undefined;
        const hex = formatHex(&buf, self.value.*, true);
        @memcpy(s.hex_buf[0..hex.len], hex);
        s.hex_len = hex.len;
        s.editing_hex = true;
    } else if (!hex_focused and s.editing_hex) {
        try commitHexInput(self, app, s, true);
        s.editing_hex = false;
    }

    if (hex_focused) {
        var changed = false;
        var commit = false;
        for (ui.input.chars) |ch| {
            if (ch == 0) break;
            if (s.hex_len >= s.hex_buf.len) continue;

            const c: u8 = switch (ch) {
                '#' => '#',
                '0'...'9' => @intCast(ch),
                'a'...'f' => @as(u8, @intCast(ch)) - 'a' + 'A',
                'A'...'F' => @intCast(ch),
                else => continue,
            };

            if (c == '#' and s.hex_len != 0) continue;
            if (s.hex_len == 0 and c != '#') s.hex_buf[s.hex_len] = '#';
            if (s.hex_len == 0 and c != '#') s.hex_len += 1;
            if (s.hex_len < s.hex_buf.len) {
                s.hex_buf[s.hex_len] = c;
                s.hex_len += 1;
                changed = true;
            }
        }

        for (ui.input.key_events) |event| {
            if (event.action == .release) continue;
            switch (event.key) {
                .backspace => if (s.hex_len > 0) {
                    s.hex_len -= 1;
                    changed = true;
                },
                .delete => {
                    s.hex_len = 0;
                    changed = true;
                },
                .enter => commit = true,
                .escape => {
                    s.editing_hex = false;
                    var buf: [10]u8 = undefined;
                    const hex = formatHex(&buf, self.value.*, true);
                    @memcpy(s.hex_buf[0..hex.len], hex);
                    s.hex_len = hex.len;
                },
                else => {},
            }
        }

        if (changed) try commitHexInput(self, app, s, false);
        if (commit) try commitHexInput(self, app, s, true);
        ui.input.consumeKeyboard();
    }
}

fn commitHexInput(self: *const ColorPicker, app: *App, s: *State.ColorPicker, allow_shorthand: bool) !void {
    const hex = s.hex_buf[0..s.hex_len];
    if (!isCommittableHexLen(hex, allow_shorthand)) return;
    if (Color.hex(hex)) |color| try setColor(self, app, s, color) else |_| {}
}

fn isCommittableHexLen(hex: []const u8, allow_shorthand: bool) bool {
    if (hex.len == 0) return false;
    const len = if (hex[0] == '#') hex.len - 1 else hex.len;
    return len == 6 or len == 8 or (allow_shorthand and (len == 3 or len == 4));
}

fn renderPopover(self: *const ColorPicker, app: *App, s: *State.ColorPicker) !void {
    const ui = &app.ui;
    const anchor = s.anchor_box;
    const viewport = s.viewport_box;
    const popup_id = self.key.indexed(POPUP_INDEX).hash();

    const line_h = try ui.lineHeight(self.size.resolve(), null);
    const popup_h = self.sv_height + self.strip_height * 2 + line_h + 76;
    const viewport_bottom = viewport.y() + viewport.h();
    const space_below = viewport_bottom - (anchor.y() + anchor.h());
    const space_above = anchor.y() - viewport.y();
    const open_above = popup_h > space_below and space_above > space_below;
    const max_h = if (open_above) space_above else space_below;
    const popup_y = if (open_above) anchor.y() - @min(popup_h, max_h) else anchor.y() + anchor.h();

    _ = try ui.state.getOrCreate(.measured, ui.allocator, popup_id);
    _ = try ui.openRoot(self.key.indexed(POPUP_INDEX), anchor.x(), popup_y, .{
        .direction = .column,
        .width = .fixed(self.popover_width),
        .height = .{ .kind = .fit, .max = max_h },
        .overflow = .scroll_y,
        .z_index = 1,
        .padding = .init(10, 10, 10, 10),
        .gap = 8,
        .interactive = true,
    }, .{ .rect = self.popover_style.toRect(&ui.theme) });

    try self.renderSvControl(app, s);
    try self.renderHueControl(app, s);
    try self.renderAlphaControl(app, s);
    try self.renderPreview(app, s);
    try self.renderHexField(app, s);

    ui.close();
}

fn isPointerInside(self: *const ColorPicker, app: *App, s: *const State.ColorPicker) bool {
    const ui = &app.ui;
    const p = .{ @as(f32, @floatCast(ui.input.mouse_pos[0])), @as(f32, @floatCast(ui.input.mouse_pos[1])) };
    if (s.anchor_box.contains(p)) return true;

    const popup_id = self.key.indexed(POPUP_INDEX).hash();
    if (ui.state.get(.measured, popup_id)) |m| {
        if (m.box.contains(p)) return true;
    }

    return false;
}

fn renderSvControl(self: *const ColorPicker, app: *App, s: *State.ColorPicker) !void {
    const ui = &app.ui;
    const id = self.key.indexed(SV_INDEX).hash();
    _ = try ui.state.getOrCreate(.measured, ui.allocator, id);

    var cmds: std.ArrayList(Decoration.DrawCmd) = .empty;
    const arena = app.arena();
    const w = self.popover_width - 20;
    const h = self.sv_height;
    const hue_color = hsvToLinearColor(s.hue, 1, 1, 1);
    const marker_x = s.saturation * w;
    const marker_y = (1.0 - s.value) * h;

    try cmds.append(arena, .{ .fill_rect = .{
        .x = 0,
        .y = 0,
        .w = w,
        .h = h,
        .color = hue_color.value,
        .corner_radius = .all(4),
    } });
    try cmds.append(arena, .{ .fill_rect_gradient = .{
        .x = 0,
        .y = 0,
        .w = w,
        .h = h,
        .colors = .{
            .{ 1, 1, 1, 1 },
            .{ 1, 1, 1, 0 },
            .{ 1, 1, 1, 0 },
            .{ 1, 1, 1, 1 },
        },
        .corner_radius = .all(4),
    } });
    try cmds.append(arena, .{ .fill_rect_gradient = .{
        .x = 0,
        .y = 0,
        .w = w,
        .h = h,
        .colors = .{
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 0 },
            .{ 0, 0, 0, 1 },
            .{ 0, 0, 0, 1 },
        },
        .corner_radius = .all(4),
    } });
    try cmds.append(arena, .{ .stroke_rect = .{ .x = 0.5, .y = 0.5, .w = w - 1, .h = h - 1, .color = .{ 0, 0, 0, 0.35 }, .corner_radius = .all(3.5) } });
    try cmds.append(arena, .{ .stroke_circle = .{ .cx = marker_x, .cy = marker_y, .radius = 6, .color = .{ 1, 1, 1, 1 }, .thickness = 2 } });
    try cmds.append(arena, .{ .stroke_circle = .{ .cx = marker_x, .cy = marker_y, .radius = 7, .color = .{ 0, 0, 0, 0.65 }, .thickness = 1 } });

    _ = try ui.open(self.key.indexed(SV_INDEX), .{
        .width = .grow(),
        .height = .fixed(h),
        .interactive = true,
    }, .{ .canvas = .{ .cmds = cmds.items } });
    ui.close();
}

fn renderHueControl(self: *const ColorPicker, app: *App, s: *State.ColorPicker) !void {
    const ui = &app.ui;
    const id = self.key.indexed(HUE_INDEX).hash();
    _ = try ui.state.getOrCreate(.measured, ui.allocator, id);

    var cmds: std.ArrayList(Decoration.DrawCmd) = .empty;
    const arena = app.arena();
    const w = self.popover_width - 20;
    const h = self.strip_height;
    const segment_w = w / 6.0;

    for (0..6) |i| {
        const x = @as(f32, @floatFromInt(i)) * segment_w;
        const c0 = hsvToLinearColor(@as(f32, @floatFromInt(i)) / 6.0, 1, 1, 1).value;
        const c1 = hsvToLinearColor(@as(f32, @floatFromInt(i + 1)) / 6.0, 1, 1, 1).value;
        try cmds.append(arena, .{ .fill_rect_gradient = .{
            .x = x,
            .y = 0,
            .w = if (i == 5) w - x else segment_w,
            .h = h,
            .colors = .{ c0, c1, c1, c0 },
            .corner_radius = .zero,
        } });
    }

    const marker_x = s.hue * w;
    try cmds.append(arena, .{ .stroke_rect = .{ .x = 0.5, .y = 0.5, .w = w - 1, .h = h - 1, .color = .{ 0, 0, 0, 0.35 }, .corner_radius = .all(3) } });
    try cmds.append(arena, .{ .line = .{ .from = .{ marker_x, -2 }, .to = .{ marker_x, h + 2 }, .color = .{ 1, 1, 1, 1 }, .thickness = 3 } });
    try cmds.append(arena, .{ .line = .{ .from = .{ marker_x, -2 }, .to = .{ marker_x, h + 2 }, .color = .{ 0, 0, 0, 0.65 }, .thickness = 1 } });

    _ = try ui.open(self.key.indexed(HUE_INDEX), .{
        .width = .grow(),
        .height = .fixed(h),
        .interactive = true,
    }, .{ .canvas = .{ .cmds = cmds.items } });
    ui.close();
}

fn renderAlphaControl(self: *const ColorPicker, app: *App, s: *State.ColorPicker) !void {
    const ui = &app.ui;
    const id = self.key.indexed(ALPHA_INDEX).hash();
    _ = try ui.state.getOrCreate(.measured, ui.allocator, id);

    var cmds: std.ArrayList(Decoration.DrawCmd) = .empty;
    const arena = app.arena();
    const w = self.popover_width - 20;
    const h = self.strip_height;
    try appendCheckerboard(&cmds, arena, w, h, 8);

    const solid = hsvToLinearColor(s.hue, s.saturation, s.value, 1).value;
    const transparent = .{ solid[0], solid[1], solid[2], 0 };
    try cmds.append(arena, .{ .fill_rect_gradient = .{
        .x = 0,
        .y = 0,
        .w = w,
        .h = h,
        .colors = .{ transparent, solid, solid, transparent },
        .corner_radius = .all(3),
    } });
    const marker_x = s.alpha * w;
    try cmds.append(arena, .{ .stroke_rect = .{ .x = 0.5, .y = 0.5, .w = w - 1, .h = h - 1, .color = .{ 0, 0, 0, 0.35 }, .corner_radius = .all(3) } });
    try cmds.append(arena, .{ .line = .{ .from = .{ marker_x, -2 }, .to = .{ marker_x, h + 2 }, .color = .{ 1, 1, 1, 1 }, .thickness = 3 } });
    try cmds.append(arena, .{ .line = .{ .from = .{ marker_x, -2 }, .to = .{ marker_x, h + 2 }, .color = .{ 0, 0, 0, 0.65 }, .thickness = 1 } });

    _ = try ui.open(self.key.indexed(ALPHA_INDEX), .{
        .width = .grow(),
        .height = .fixed(h),
        .interactive = true,
    }, .{ .canvas = .{ .cmds = cmds.items } });
    ui.close();
}

fn renderPreview(self: *const ColorPicker, app: *App, s: *State.ColorPicker) !void {
    const ui = &app.ui;
    var cmds: std.ArrayList(Decoration.DrawCmd) = .empty;
    const arena = app.arena();
    const w = self.popover_width - 20;
    const h: f32 = 28;
    const half = w * 0.5;
    const original = if (s.has_original) s.original_color else self.value.value;

    try appendCheckerboard(&cmds, arena, w, h, 7);
    try cmds.append(arena, .{ .fill_rect = .{ .x = 0, .y = 0, .w = half, .h = h, .color = original, .corner_radius = .all(4) } });
    try cmds.append(arena, .{ .fill_rect = .{ .x = half, .y = 0, .w = half, .h = h, .color = self.value.value, .corner_radius = .all(4) } });
    try cmds.append(arena, .{ .line = .{ .from = .{ half, 0 }, .to = .{ half, h }, .color = .{ 0, 0, 0, 0.35 }, .thickness = 1 } });
    try cmds.append(arena, .{ .stroke_rect = .{ .x = 0.5, .y = 0.5, .w = w - 1, .h = h - 1, .color = .{ 0, 0, 0, 0.35 }, .corner_radius = .all(3.5) } });

    _ = try ui.open(self.key.indexed(PREVIEW_INDEX), .{
        .width = .grow(),
        .height = .fixed(h),
    }, .{ .canvas = .{ .cmds = cmds.items } });
    ui.close();
}

fn renderHexField(self: *const ColorPicker, app: *App, s: *State.ColorPicker) !void {
    const ui = &app.ui;
    const id = self.key.indexed(HEX_INDEX).hash();
    const focused = ui.focused(id);
    const style = if (focused) self.focused_style else self.style;
    const line_h = try ui.lineHeight(self.size.resolve(), null);

    _ = try ui.open(self.key.indexed(HEX_INDEX), .{
        .width = .grow(),
        .height = .fixed(line_h + 12),
        .alignment = .center,
        .padding = .init(0, 8, 0, 8),
        .interactive = true,
    }, .{ .rect = style.toRect(&ui.theme) });

    const display = if (s.editing_hex)
        s.hex_buf[0..s.hex_len]
    else
        try formatHexAlloc(app.arena(), self.value.*, true);
    var deco = try ui.textDecoration(display, self.size.resolve(), null, false);
    deco.text.color = self.text_color.resolve(&ui.theme);
    _ = try ui.open(self.key.indexed(HEX_INDEX + 100), .{ .width = .fit(), .height = .fit() }, deco);
    ui.close();

    ui.close();
}

fn syncStateFromColor(s: *State.ColorPicker, color: Color) void {
    const srgb = linearRgbaToSrgb(color.value);
    const hsv = rgbToHsv(srgb[0], srgb[1], srgb[2], s.hue);
    if (hsv.s > 0.001) s.hue = hsv.h;
    s.saturation = hsv.s;
    s.value = hsv.v;
    s.alpha = srgb[3];
}

fn setColorFromState(self: *const ColorPicker, app: *App, s: *State.ColorPicker) !void {
    try setColor(self, app, s, hsvToLinearColor(s.hue, s.saturation, s.value, s.alpha));
}

fn setColor(self: *const ColorPicker, app: *App, s: *State.ColorPicker, color: Color) !void {
    if (std.meta.eql(self.value.value, color.value)) return;
    self.value.* = color;
    syncStateFromColor(s, color);
    if (self.onChange) |cb| try cb(app);
}

fn pointInBox(m: *const State.Measured, mouse_pos: [2]f64) [2]f32 {
    const x = std.math.clamp((@as(f32, @floatCast(mouse_pos[0])) - m.box.x()) / @max(m.width, 1), 0, 1);
    const y = std.math.clamp((@as(f32, @floatCast(mouse_pos[1])) - m.box.y()) / @max(m.height, 1), 0, 1);
    return .{ x, y };
}

fn appendCheckerboard(cmds: *std.ArrayList(Decoration.DrawCmd), allocator: std.mem.Allocator, w: f32, h: f32, cell: f32) !void {
    var y: f32 = 0;
    var row: usize = 0;
    while (y < h) : ({
        y += cell;
        row += 1;
    }) {
        var x: f32 = 0;
        var col: usize = 0;
        while (x < w) : ({
            x += cell;
            col += 1;
        }) {
            try cmds.append(allocator, .{ .fill_rect = .{
                .x = x,
                .y = y,
                .w = @min(cell, w - x),
                .h = @min(cell, h - y),
                .color = checkerColor((row + col) & 1),
            } });
        }
    }
}

fn checkerColor(index: usize) [4]f32 {
    return if (index == 0) .{ 0.82, 0.82, 0.82, 1 } else .{ 0.58, 0.58, 0.58, 1 };
}

const Hsv = struct { h: f32, s: f32, v: f32 };

fn rgbToHsv(r: f32, g: f32, b: f32, fallback_hue: f32) Hsv {
    const max_c = @max(r, @max(g, b));
    const min_c = @min(r, @min(g, b));
    const delta = max_c - min_c;
    if (delta <= 0.00001) return .{ .h = fallback_hue, .s = 0, .v = max_c };

    var h: f32 = if (max_c == r)
        @mod((g - b) / delta, 6.0)
    else if (max_c == g)
        ((b - r) / delta) + 2.0
    else
        ((r - g) / delta) + 4.0;
    h /= 6.0;
    if (h < 0) h += 1.0;

    return .{ .h = h, .s = if (max_c == 0) 0 else delta / max_c, .v = max_c };
}

fn hsvToLinearColor(h_: f32, s: f32, v: f32, a: f32) Color {
    const h = @mod(h_, 1.0) * 6.0;
    const c = v * s;
    const x = c * (1.0 - @abs(@mod(h, 2.0) - 1.0));
    const m = v - c;

    const rgb: [3]f32 = if (h < 1.0)
        .{ c, x, 0 }
    else if (h < 2.0)
        .{ x, c, 0 }
    else if (h < 3.0)
        .{ 0, c, x }
    else if (h < 4.0)
        .{ 0, x, c }
    else if (h < 5.0)
        .{ x, 0, c }
    else
        .{ c, 0, x };

    return .{ .value = .{
        Color.srgbToLinear(rgb[0] + m),
        Color.srgbToLinear(rgb[1] + m),
        Color.srgbToLinear(rgb[2] + m),
        std.math.clamp(a, 0, 1),
    } };
}

fn linearRgbaToSrgb(rgba: [4]f32) [4]f32 {
    return .{
        std.math.clamp(Color.linearToSrgb(rgba[0]), 0, 1),
        std.math.clamp(Color.linearToSrgb(rgba[1]), 0, 1),
        std.math.clamp(Color.linearToSrgb(rgba[2]), 0, 1),
        std.math.clamp(rgba[3], 0, 1),
    };
}

fn formatHex(buf: *[10]u8, color: Color, include_alpha: bool) []const u8 {
    const srgb = linearRgbaToSrgb(color.value);
    const r = toByte(srgb[0]);
    const g = toByte(srgb[1]);
    const b = toByte(srgb[2]);
    const a = toByte(srgb[3]);
    if (include_alpha) {
        return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b, a }) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ r, g, b }) catch unreachable;
}

fn formatHexAlloc(allocator: std.mem.Allocator, color: Color, include_alpha: bool) ![]const u8 {
    var buf: [10]u8 = undefined;
    const hex = formatHex(&buf, color, include_alpha);
    return try allocator.dupe(u8, hex);
}

fn toByte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255.0));
}
