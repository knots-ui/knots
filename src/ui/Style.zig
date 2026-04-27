const Decoration = @import("decoration.zig").Decoration;
const Theme = @import("Theme.zig");
const Color = @import("Color.zig");
const Radius = Theme.Radius;

color: Color.Input = .{ .color = Color.transparent },
corner_radius: Radius = .md,
border_width: f32 = 0,
border_color: Color.Input = .{ .color = Color.transparent },

const Style = @This();

/// All-optional variant for state overrides. Null fields fall back to base.
pub const Override = struct {
    color: ?Color.Input = null,
    corner_radius: ?Radius = null,
    border_width: ?f32 = null,
    border_color: ?Color.Input = null,
};

/// Merge base style with an override (non-null fields win).
pub fn merge(base: Style, over: Override) Style {
    return .{
        .color = over.color orelse base.color,
        .corner_radius = over.corner_radius orelse base.corner_radius,
        .border_width = over.border_width orelse base.border_width,
        .border_color = over.border_color orelse base.border_color,
    };
}

/// Returns true if this style would produce a visible decoration.
pub fn hasDecoration(self: Style) bool {
    return !self.color.isTransparent() or self.border_width != 0;
}

/// Convert to layout Decoration.Rect
pub fn toRect(self: Style) Decoration.Rect {
    return .{
        .color = self.color.resolve(),
        .corner_radius = self.corner_radius.resolve(),
        .border_width = self.border_width,
        .border_color = self.border_color.resolve(),
    };
}
