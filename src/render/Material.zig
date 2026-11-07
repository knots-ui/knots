//! How a backdrop filters what is painted behind an element, in logical pixels.
//! Zero fields disable their effect.
const std = @import("std");

/// Gaussian-equivalent sigma.
blur: f32 = 0,
/// 1 keeps the backdrop's saturation.
saturation: f32 = 1,
/// Maximum refraction displacement at the rim. Needs a nonzero `bezel`.
refraction: f32 = 0,
/// Width of the rim over which the glass curves.
bezel: f32 = 0,
/// Chromatic split, as a fraction of the displacement.
dispersion: f32 = 0,
/// Rim highlight intensity.
specular: f32 = 0,

const Material = @This();

pub const none: Material = .{};
pub const frosted: Material = .{ .blur = 16, .saturation = 1.6 };
pub const glass: Material = .{ .blur = 2, .saturation = 1.5, .refraction = 12, .bezel = 16, .dispersion = 0.15, .specular = 0.5 };

/// Whether drawing this would change any pixel.
pub fn isActive(self: Material) bool {
    if (self.blur > 0 or self.saturation != 1) return true;
    return self.bezel > 0 and (self.refraction > 0 or self.specular > 0);
}

pub fn isValid(self: Material) bool {
    inline for (@typeInfo(Material).@"struct".field_names) |name| {
        const value = @field(self, name);
        if (!std.math.isFinite(value) or value < 0) return false;
    }
    return true;
}

/// Largest distance a sample travels from its pixel.
pub fn reach(self: Material) f32 {
    return 3 * self.blur + self.refraction * (1 + self.dispersion);
}

pub fn lerp(a: Material, b: Material, t: f32) Material {
    var out: Material = undefined;
    inline for (@typeInfo(Material).@"struct".field_names) |name| {
        @field(out, name) = @field(a, name) + (@field(b, name) - @field(a, name)) * t;
    }
    return out;
}
