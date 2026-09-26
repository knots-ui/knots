//! The styling vocabulary shared by every component.
//!
//! Every field is optional; `null` means "this layer does not set it".
//! Layout fields become `layout.Element.Config`, surface fields become a
//! `Surface`, and content fields are inherited by descendants when unset.
const std = @import("std");
const math = @import("math");
const layout = @import("layout");

const Element = layout.Element;
const Grid = layout.Grid;
const Layer = layout.Layer;
const Color = @import("Color.zig");
const Radius = @import("Radius.zig");
const BorderWidth = @import("BorderWidth.zig");
const FontSize = @import("FontSize.zig");
const Theme = @import("Theme.zig");

pub const Tone = Color.Tone;

pub const States = packed struct(u8) {
    hover: bool = false,
    focus: bool = false,
    active: bool = false,
    checked: bool = false,
    open: bool = false,
    disabled: bool = false,
    _: u2 = 0,

    pub fn any(self: States) bool {
        return @as(u8, @bitCast(self)) != 0;
    }
};

pub const Transition = struct {
    duration_ms: u16 = 120,
    ease: math.Ease = .smooth_step,
};

// Layout → layout.Element.Config (never animated)
width: ?Element.sizing.Axis = null,
height: ?Element.sizing.Axis = null,
padding: ?Element.Padding = null,
gap: ?f32 = null,
direction: ?Element.Direction = null,
@"align": ?Element.Align = null,
justify: ?Element.Justify = null,
overflow: ?Element.Overflow = null,
position: ?Element.Position = null,
offset: ?[2]f32 = null,
layer: ?Layer = null,
/// On grid containers.
grid: ?Grid.Template = null,
/// On grid children.
grid_cell: ?Grid.Placement = null,

// Surface → Surface
background: ?Color.Input = null,
border_width: ?BorderWidth = null,
border_color: ?Color.Input = null,
radius: ?Radius.Input = null,
/// Mix `foreground` over `background` by this amount: hover/press feedback that works on any background.
state_layer: ?f32 = null,
/// Multiplies all resolved alphas of this element.
opacity: ?f32 = null,

// Content (inherited by descendants when unset)
/// Text, icons, check marks, image tint.
foreground: ?Color.Input = null,
font: ?[]const u8 = null,
font_size: ?FontSize.Input = null,
/// Rebinds `.accent` / `.on_accent` for the subtree.
tone: ?Tone = null,
/// Not inherited.
wrap: ?bool = null,

// State variants (nesting = AND: checked.hover)
hover: ?*const Style = null,
focus: ?*const Style = null,
active: ?*const Style = null,
checked: ?*const Style = null,
open: ?*const Style = null,
disabled: ?*const Style = null,

// Motion (surface + foreground only)
transition: ?Transition = null,

const Style = @This();

/// Fixed application order; `disabled` is last so it wins.
const variant_names = [_][]const u8{ "hover", "focus", "active", "checked", "open", "disabled" };

const prop_names = blk: {
    const all = @typeInfo(Style).@"struct".field_names;
    var names: [all.len - variant_names.len][]const u8 = undefined;
    var n: usize = 0;
    for (all) |name| {
        if (isVariant(name)) continue;
        names[n] = name;
        n += 1;
    }
    std.debug.assert(n == names.len);
    const out = names;
    break :blk out;
};

fn isVariant(comptime name: []const u8) bool {
    for (variant_names) |v| if (std.mem.eql(u8, v, name)) return true;
    return false;
}

/// Sparse merge: fields set in `over` win. Comptime or runtime.
pub fn with(base: Style, over: Style) Style {
    var out = base;
    inline for (@typeInfo(Style).@"struct".field_names) |name| {
        if (@field(over, name)) |v| @field(out, name) = v;
    }
    return out;
}

fn mergeProps(out: *Style, s: *const Style) void {
    inline for (prop_names) |name| {
        if (@field(s.*, name)) |v| @field(out.*, name) = v;
    }
}

fn applyStates(out: *Style, s: *const Style, st: States) void {
    inline for (variant_names) |name| {
        if (@field(st, name)) {
            if (@field(s.*, name)) |variant| {
                mergeProps(out, variant);
                var rest = st;
                @field(rest, name) = false;
                if (rest.any()) applyStates(out, variant, rest);
            }
        }
    }
}

// ── Resolved output

pub const Surface = struct {
    /// Resolved background, state_layer and opacity applied.
    color: [4]f32 = .{ 0, 0, 0, 0 },
    corner_radius: Radius = .zero,
    border_width: BorderWidth = .zero,
    border_color: [4]f32 = .{ 0, 0, 0, 0 },

    pub fn isVisible(self: Surface) bool {
        return self.color[3] > 0 or (!self.border_width.isZero() and self.border_color[3] > 0);
    }
};

/// Inherited scope.
pub const Content = struct {
    foreground: [4]f32,
    font: ?[]const u8,
    font_size: f32,
    tone: Tone,

    /// Resolve a color in this scope (`.accent` follows the tone, `.current` is the foreground).
    pub fn color(self: *const Content, input: Color.Input, theme: *const Theme) [4]f32 {
        return input.resolveIn(theme, self.tone, self.foreground);
    }
};

/// Non-optional mirror of the layout fields.
pub const Layout = struct {
    width: Element.sizing.Axis = .fit(),
    height: Element.sizing.Axis = .fit(),
    padding: Element.Padding = .init(0, 0, 0, 0),
    gap: f32 = 0,
    direction: Element.Direction = .row,
    @"align": Element.Align = .start,
    justify: Element.Justify = .start,
    overflow: Element.Overflow = .visible,
    position: Element.Position = .static,
    offset: [2]f32 = .{ 0, 0 },
    layer: Layer = .base,
    grid: ?Grid.Template = null,
    grid_cell: ?Grid.Placement = null,
};

/// The animatable part of a resolved style.
pub const Visual = struct {
    surface: Surface,
    foreground: [4]f32,

    pub fn eql(a: Visual, b: Visual) bool {
        return std.meta.eql(a, b);
    }

    pub fn lerp(a: Visual, b: Visual, t: f32) Visual {
        return .{
            .surface = .{
                .color = lerp4(a.surface.color, b.surface.color, t),
                .corner_radius = .lerp(a.surface.corner_radius, b.surface.corner_radius, t),
                .border_width = .lerp(a.surface.border_width, b.surface.border_width, t),
                .border_color = lerp4(a.surface.border_color, b.surface.border_color, t),
            },
            .foreground = lerp4(a.foreground, b.foreground, t),
        };
    }
};

pub const Resolved = struct {
    layout: Layout,
    surface: Surface,
    content: Content,
    wrap: bool,
    transition: ?Transition,

    pub const Flags = struct { interactive: bool = false, focusable: bool = false };

    pub fn element(self: *const Resolved, flags: Flags) Element.Config {
        const l = &self.layout;
        return .{
            .width = l.width,
            .height = l.height,
            .padding = l.padding,
            .gap = l.gap,
            .direction = l.direction,
            .alignment = l.@"align",
            .justify = l.justify,
            .interactive = flags.interactive,
            .focusable = flags.focusable,
            .overflow = l.overflow,
            .position = l.position,
            .z_index = l.layer.index(),
            .offset = l.offset,
            .grid_template = l.grid,
            .grid_placement = l.grid_cell,
        };
    }

    pub fn visual(self: *const Resolved) Visual {
        return .{ .surface = self.surface, .foreground = self.content.foreground };
    }

    pub fn setVisual(self: *Resolved, v: Visual) void {
        self.surface = v.surface;
        self.content.foreground = v.foreground;
    }
};

pub const Cascade = struct {
    /// Component default (comptime const).
    base: *const Style,
    /// What the caller passed.
    user: *const Style,
};

/// Merge + theme-resolve. Deterministic; no allocation.
pub fn resolve(cascade: Cascade, states: States, parent: *const Content, theme: *const Theme) Resolved {
    var props: Style = .{};
    mergeProps(&props, cascade.base);
    mergeProps(&props, cascade.user);

    var st = states;
    if (st.disabled) {
        st.hover = false;
        st.focus = false;
        st.active = false;
    }
    if (st.any()) {
        applyStates(&props, cascade.base, st);
        applyStates(&props, cascade.user, st);
    }
    return resolveProps(&props, parent, theme);
}

fn resolveProps(props: *const Style, parent: *const Content, theme: *const Theme) Resolved {
    var l: Layout = .{};
    inline for (@typeInfo(Layout).@"struct".field_names) |name| {
        if (@field(props.*, name)) |v| @field(l, name) = v;
    }

    const tone = props.tone orelse parent.tone;
    var content: Content = .{
        .foreground = if (props.foreground) |c| c.resolveIn(theme, tone, parent.foreground) else parent.foreground,
        .font = props.font orelse parent.font,
        .font_size = if (props.font_size) |f| f.resolve(theme) else parent.font_size,
        .tone = tone,
    };
    const fg = content.foreground;

    var surface: Surface = .{
        .color = if (props.background) |c| c.resolveIn(theme, tone, fg) else Color.transparent.value,
        .corner_radius = if (props.radius) |r| r.resolve(theme) else .zero,
        .border_width = props.border_width orelse .zero,
        .border_color = if (props.border_color) |c| c.resolveIn(theme, tone, fg) else Color.transparent.value,
    };
    if (props.state_layer) |amount| surface.color = composite(surface.color, fg, amount);
    if (props.opacity) |o| {
        surface.color[3] *= o;
        surface.border_color[3] *= o;
        content.foreground[3] *= o;
    }

    return .{
        .layout = l,
        .surface = surface,
        .content = content,
        .wrap = props.wrap orelse false,
        .transition = props.transition,
    };
}

/// Root content for a UI (theme text color, default font, theme sm size, primary tone).
pub fn rootContent(theme: *const Theme) Content {
    return .{
        .foreground = theme.text.value,
        .font = null,
        .font_size = theme.font_size[1],
        .tone = .primary,
    };
}

/// Composite `fg` with coverage `amount` over `bg` (premultiplied-correct "over").
fn composite(bg: [4]f32, fg: [4]f32, amount: f32) [4]f32 {
    const a = std.math.clamp(amount, 0, 1) * fg[3];
    const out_a = a + bg[3] * (1 - a);
    if (out_a <= 0) return .{ 0, 0, 0, 0 };
    return .{
        (fg[0] * a + bg[0] * bg[3] * (1 - a)) / out_a,
        (fg[1] * a + bg[1] * bg[3] * (1 - a)) / out_a,
        (fg[2] * a + bg[2] * bg[3] * (1 - a)) / out_a,
        out_a,
    };
}

fn lerp4(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return math.lerp(@as(math.Vec4, a), @as(math.Vec4, b), t);
}
