const std = @import("std");
const style = @import("root.zig");

const Style = style.Style;
const Theme = style.Theme;
const Color = style.Color;

const theme = Theme.dark;
const expectEqual = std.testing.expectEqual;

fn resolveWith(base: *const Style, user: *const Style, st: style.States) style.Resolved {
    const root = style.rootContent(&theme);
    return style.resolve(.{ .base = base, .user = user }, st, &root, &theme);
}

test "user style is a delta over the base" {
    const base: Style = .{ .background = .elevated, .border_width = .all(1), .border_color = .toned };
    const r = resolveWith(&base, &.{ .radius = .lg }, .{});
    try expectEqual(theme.elevated.value, r.surface.color);
    try expectEqual(theme.toned.value, r.surface.border_color);
    try expectEqual(theme.radius.scale(1.5), r.surface.corner_radius);
}

test "states apply after plain props and survive user recoloring" {
    const base: Style = .{ .background = .muted, .hover = &.{ .border_color = .accent } };
    const r = resolveWith(&base, &.{ .background = .success, .border_color = .toned }, .{ .hover = true });
    try expectEqual(theme.success.value, r.surface.color);
    try expectEqual(theme.primary.value, r.surface.border_color);
}

test "user state variant overrides base state variant" {
    const base: Style = .{ .hover = &.{ .state_layer = 0.2 } };
    const r = resolveWith(&base, &.{ .background = .muted, .hover = &.{ .state_layer = 0 } }, .{ .hover = true });
    try expectEqual(theme.muted.value, r.surface.color);
}

test "nested variants require every state" {
    const base: Style = .{ .checked = &.{ .background = .accent, .hover = &.{ .border_color = .success } } };
    const checked = resolveWith(&base, &.{}, .{ .checked = true });
    try expectEqual(theme.primary.value, checked.surface.color);
    try expectEqual(Color.transparent.value, checked.surface.border_color);

    const both = resolveWith(&base, &.{}, .{ .checked = true, .hover = true });
    try expectEqual(theme.success.value, both.surface.border_color);

    const hover_only = resolveWith(&base, &.{}, .{ .hover = true });
    try expectEqual(Color.transparent.value, hover_only.surface.color);
}

test "disabled clears hover focus and active" {
    const base: Style = .{
        .background = .muted,
        .hover = &.{ .background = .success },
        .disabled = &.{ .opacity = 0.5 },
    };
    const r = resolveWith(&base, &.{}, .{ .hover = true, .disabled = true });
    try expectEqual(theme.muted.value[0], r.surface.color[0]);
    try expectEqual(theme.muted.value[3] * 0.5, r.surface.color[3]);
}

test "tone rebinds accent and on_accent" {
    const base: Style = .{ .background = .accent, .foreground = .on_accent };
    const r = resolveWith(&base, &.{ .tone = .@"error" }, .{});
    try expectEqual(theme.@"error".value, r.surface.color);
    try expectEqual(theme.on_error.value, r.content.foreground);
    try expectEqual(style.Tone.@"error", r.content.tone);
}

test "content inherits from parent and current follows foreground" {
    var parent = style.rootContent(&theme);
    parent.font = "mono";
    parent.tone = .success;
    const r = style.resolve(.{ .base = &.{ .border_color = .current }, .user = &.{} }, .{}, &parent, &theme);
    try expectEqual(theme.text.value, r.content.foreground);
    try expectEqual(theme.text.value, r.surface.border_color);
    try std.testing.expectEqualStrings("mono", r.content.font.?);
    try expectEqual(theme.font_size[1], r.content.font_size);
    try expectEqual(style.Tone.success, r.content.tone);
}

test "font size tokens resolve through the theme" {
    const r = resolveWith(&.{ .font_size = .lg }, &.{}, .{});
    try expectEqual(theme.font_size[3], r.content.font_size);
    const px = resolveWith(&.{ .font_size = .{ .px = 13 } }, &.{}, .{});
    try expectEqual(@as(f32, 13), px.content.font_size);
}

test "state layer composites foreground over background" {
    const white: Color = .{ .value = .{ 1, 1, 1, 1 } };
    const black: Color = .{ .value = .{ 0, 0, 0, 1 } };
    const r = resolveWith(&.{ .background = .{ .color = black }, .foreground = .{ .color = white }, .state_layer = 0.25 }, &.{}, .{});
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), r.surface.color[0], 1e-6);
    try expectEqual(@as(f32, 1), r.surface.color[3]);

    const ghost = resolveWith(&.{ .foreground = .{ .color = white }, .state_layer = 0.25 }, &.{}, .{});
    try expectEqual([4]f32{ 1, 1, 1, 0.25 }, ghost.surface.color);
}

test "layout fields map onto the element config" {
    const r = resolveWith(&.{ .width = .grow(), .padding = .xy(8, 4), .@"align" = .center, .layer = .popup }, &.{ .gap = 3 }, .{});
    const cfg = r.element(.{ .interactive = true });
    try expectEqual(.grow, cfg.width.kind);
    try expectEqual([4]f32{ 4, 8, 4, 8 }, cfg.padding.value);
    try expectEqual(.center, cfg.alignment);
    try expectEqual(@as(f32, 3), cfg.gap);
    try expectEqual(@as(u8, 10), cfg.z_index);
    try std.testing.expect(cfg.interactive);
    try std.testing.expect(!cfg.focusable);
}

const toolbar_button: Style = .{ .height = .fixed(28), .radius = .sm };

test "with merges at comptime" {
    const b = comptime toolbar_button.with(.{ .tone = .@"error", .radius = .lg });
    try expectEqual(@as(f32, 28), b.height.?.value);
    try expectEqual(style.Radius.Input.lg, b.radius.?);
    try expectEqual(style.Tone.@"error", b.tone.?);
}

test "visual lerp interpolates surface and foreground" {
    const a: style.Visual = .{ .surface = .{}, .foreground = .{ 0, 0, 0, 0 } };
    const b: style.Visual = .{ .surface = .{ .color = .{ 1, 1, 1, 1 } }, .foreground = .{ 1, 0, 0, 1 } };
    const mid = a.lerp(b, 0.5);
    try expectEqual([4]f32{ 0.5, 0.5, 0.5, 0.5 }, mid.surface.color);
    try expectEqual([4]f32{ 0.5, 0, 0, 0.5 }, mid.foreground);
}

test "material presets, validity and interpolation" {
    const Material = style.Material;
    try std.testing.expect(!Material.none.isActive());
    try std.testing.expect(Material.frosted.isActive() and Material.glass.isActive());
    try std.testing.expect(!(Material{ .refraction = 10 }).isActive());
    try std.testing.expect(Material.glass.isValid());
    try std.testing.expect(!(Material{ .blur = -1 }).isValid());
    try std.testing.expect(!(Material{ .blur = std.math.nan(f32) }).isValid());
    try expectEqual(@as(f32, 8), Material.lerp(.none, .frosted, 0.5).blur);
}

test "backdrop resolves, fades with opacity, and animates" {
    const Material = style.Material;
    const r = resolveWith(&.{ .backdrop = .frosted }, &.{ .opacity = 0.5 }, .{});
    try expectEqual(Material.lerp(.none, .frosted, 0.5), r.surface.backdrop);
    try std.testing.expect(r.surface.isVisible());
    const hovered = resolveWith(&.{ .backdrop = .frosted }, &.{ .hover = &.{ .backdrop = .glass } }, .{ .hover = true });
    try expectEqual(Material.glass, hovered.surface.backdrop);
    const mid = style.Visual.lerp(r.visual(), hovered.visual(), 0.5);
    try expectEqual(Material.lerp(r.surface.backdrop, .glass, 0.5), mid.surface.backdrop);
    try std.testing.expect(!resolveWith(&.{}, &.{}, .{}).surface.isVisible());
}
