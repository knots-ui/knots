//! A font size in logical pixels, or a theme token.
const Theme = @import("Theme.zig");

pub const Input = union(enum) {
    xs,
    sm,
    md,
    lg,
    xl,
    px: f32,

    pub fn resolve(self: Input, theme: *const Theme) f32 {
        return switch (self) {
            .px => |v| v,
            inline else => |_, tag| theme.font_size[@intFromEnum(tag)],
        };
    }
};
