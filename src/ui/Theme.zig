const std = @import("std");
const Color = @import("Color.zig");
const Radius = @import("Radius.zig");

primary: Color,
secondary: Color,
success: Color,
info: Color,
warning: Color,
@"error": Color,
on_primary: Color,
on_secondary: Color,
on_success: Color,
on_info: Color,
on_warning: Color,
on_error: Color,
bg: Color,
muted: Color,
elevated: Color,
accented: Color,
inverted: Color,
text: Color,
highlighted: Color,
toned: Color,
dimmed: Color,
radius: Radius,

scrollbar_thickness: f32,
scrollbar_min_thumb: f32,
scrollbar_track_color: Color,
scrollbar_thumb_color: Color,
scrollbar_thumb_hover_color: Color,
scrollbar_corner_radius: Radius,

const Theme = @This();

pub const dark: Theme = parse(@import("themes/dark.zon"));
pub const light: Theme = parse(@import("themes/light.zon"));

pub fn parse(comptime def: anytype) Theme {
    const Def = @TypeOf(def);
    inline for (std.meta.fields(Theme)) |field| {
        if (!@hasField(Def, field.name))
            @compileError("theme is missing required field: " ++ field.name);
    }
    return parseWithBase(std.mem.zeroes(Theme), def);
}

pub fn parseWithBase(comptime base: Theme, comptime def: anytype) Theme {
    var res = base;
    inline for (std.meta.fields(@TypeOf(def))) |field| {
        if (!@hasField(Theme, field.name))
            @compileError("unknown theme field: " ++ field.name);
        const v = @field(def, field.name);
        const Field = @TypeOf(@field(res, field.name));
        if (Field == Radius) {
            @field(res, field.name) = parseRadius(v);
            continue;
        }
        if (@TypeOf(v) == comptime_float or @TypeOf(v) == comptime_int or @TypeOf(v) == f32) {
            @field(res, field.name) = v;
            continue;
        }

        const T = @TypeOf(v);

        @field(res, field.name) = if (@hasField(T, "hex"))
            Color.hex(@field(v, "hex")) catch |err| @compileError("failed to parse hex with error " ++ @errorName(err) ++ ": " ++ @field(v, "hex"))
        else if (@hasField(T, "rgba")) blk: {
            const rgba = @field(v, "rgba");
            break :blk Color.rgba(rgba[0], rgba[1], rgba[2], rgba[3]);
        } else if (@hasField(T, "rgb")) blk: {
            const rgb = @field(v, "rgb");
            break :blk Color.rgba(rgb[0], rgb[1], rgb[2], 1);
        } else @compileError("boom");
    }
    return res;
}

fn parseRadius(comptime def: anytype) Radius {
    const T = @TypeOf(def);
    if (T == comptime_float or T == comptime_int or T == f32) return Radius.all(def);
    if (@hasField(T, "fixed")) return Radius.all(@field(def, "fixed"));
    if (@hasField(T, "corners")) {
        const corners = @field(def, "corners");
        return Radius.corners(corners[0], corners[1], corners[2], corners[3]);
    }
    if (@hasField(T, "value")) {
        const value = @field(def, "value");
        return Radius.corners(value[0], value[1], value[2], value[3]);
    }
    @compileError("failed to parse radius");
}
