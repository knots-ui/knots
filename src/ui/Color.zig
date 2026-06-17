const std = @import("std");
const Theme = @import("Theme.zig");

pub const Input = union(enum) {
    primary,
    secondary,
    success,
    info,
    warning,
    @"error",
    on_primary,
    on_secondary,
    on_success,
    on_info,
    on_warning,
    on_error,
    bg,
    muted,
    elevated,
    accented,
    inverted,
    text,
    highlighted,
    toned,
    dimmed,
    color: Color,

    pub fn resolve(self: Input, theme: *const Theme) [4]f32 {
        return switch (self) {
            .color => |c| c.value,
            inline else => |_, tag| @field(theme.*, @tagName(tag)).value,
        };
    }

    pub fn isTransparent(self: Input) bool {
        return switch (self) {
            .color => |c| c.value[3] == 0,
            else => false,
        };
    }

    pub fn onColor(self: Input) ?Input {
        return switch (self) {
            .primary => .on_primary,
            .secondary => .on_secondary,
            .success => .on_success,
            .info => .on_info,
            .warning => .on_warning,
            .@"error" => .on_error,
            else => null,
        };
    }
};

value: [4]f32,

const Color = @This();

pub const transparent: Color = .{ .value = .{ 0, 0, 0, 0 } };

pub fn srgbToLinear(c: f32) f32 {
    @setEvalBranchQuota(10_000);
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

pub fn linearToSrgb(c: f32) f32 {
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .value = .{
        srgbToLinear(@as(f32, @floatFromInt(r)) / 255.0),
        srgbToLinear(@as(f32, @floatFromInt(g)) / 255.0),
        srgbToLinear(@as(f32, @floatFromInt(b)) / 255.0),
        @as(f32, @floatFromInt(a)) / 255.0,
    } };
}

pub fn isTransparent(self: Color) bool {
    return self.value[3] == 0;
}

const ParseHexError = error{ InvalidCharacter, InvalidLength };

/// Parses a comptime RGBA hex string into a [4]f32 array.
/// Supported formats:
///   "#RRGGBB"   — opaque (alpha = 1.0)
///   "#RRGGBBAA"
///   "#RGB"      — shorthand, each nibble doubled
///   "#RGBA"     — shorthand with alpha
/// Values are normalized to [0.0, 1.0].
pub fn hex(str: []const u8) ParseHexError!Color {
    if (str.len == 0) return ParseHexError.InvalidLength;
    const s = if (str[0] == '#') str[1..] else str;

    const parseNibble = struct {
        fn f(c: u8) ParseHexError!u8 {
            return switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return ParseHexError.InvalidCharacter,
            };
        }
    }.f;

    const parseByteSrgb = struct {
        fn f(hi: u8, lo: u8) ParseHexError!f32 {
            const s_val = @as(f32, @floatFromInt((try parseNibble(hi)) * 16 + (try parseNibble(lo)))) / 255.0;
            return srgbToLinear(s_val);
        }
    }.f;

    const parseByteAlpha = struct {
        fn f(hi: u8, lo: u8) ParseHexError!f32 {
            return @as(f32, @floatFromInt((try parseNibble(hi)) * 16 + (try parseNibble(lo)))) / 255.0;
        }
    }.f;

    return switch (s.len) {
        3 => .{ .value = .{
            try parseByteSrgb(s[0], s[0]),
            try parseByteSrgb(s[1], s[1]),
            try parseByteSrgb(s[2], s[2]),
            1.0,
        } },
        4 => .{ .value = .{
            try parseByteSrgb(s[0], s[0]),
            try parseByteSrgb(s[1], s[1]),
            try parseByteSrgb(s[2], s[2]),
            try parseByteAlpha(s[3], s[3]),
        } },
        6 => .{ .value = .{
            try parseByteSrgb(s[0], s[1]),
            try parseByteSrgb(s[2], s[3]),
            try parseByteSrgb(s[4], s[5]),
            1.0,
        } },
        8 => .{ .value = .{
            try parseByteSrgb(s[0], s[1]),
            try parseByteSrgb(s[2], s[3]),
            try parseByteSrgb(s[4], s[5]),
            try parseByteAlpha(s[6], s[7]),
        } },
        else => return ParseHexError.InvalidLength,
    };
}
