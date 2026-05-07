const Vec4f = @import("common.zig").Vec4f;
const Vec2f = @import("common.zig").Vec2f;
const uniform = @import("common.zig").uniform;
const input = @import("common.zig").input;
const output = @import("common.zig").output;

const Viewport = extern struct { size: Vec2f };

const viewport = uniform(Viewport, "viewport", .{ .descriptor = .{ .set = 0, .binding = 0 } });

const in_pos = input(Vec2f, "in_pos", .{ .location = 0 });
const in_uv = input(Vec2f, "in_uv", .{ .location = 1 });
const in_color = input(Vec4f, "in_color", .{ .location = 2 });
const in_corner_radius = input(f32, "in_corner_radius", .{ .location = 3 });
const in_half_size = input(Vec2f, "in_half_size", .{ .location = 4 });
const in_border_width = input(f32, "in_border_width", .{ .location = 5 });
const in_border_color = input(Vec4f, "in_border_color", .{ .location = 6 });
const in_prim_type = input(f32, "in_prim_type", .{ .location = 7 });

const out_color = output(Vec4f, "out_color", .{ .location = 0 });
const out_uv = output(Vec2f, "out_uv", .{ .location = 1 });
const out_corner_radius = output(f32, "out_corner_radius", .{ .location = 2 });
const out_half_size = output(Vec2f, "out_half_size", .{ .location = 3 });
const out_border_width = output(f32, "out_border_width", .{ .location = 4 });
const out_border_color = output(Vec4f, "out_border_color", .{ .location = 5 });
const out_prim_type = output(f32, "out_prim_type", .{ .location = 6 });

extern var position: Vec4f addrspace(.output);

export fn main() callconv(.spirv_vertex) void {
    const ndc = (in_pos.* / viewport.*.size) * @as(Vec2f, @splat(2.0)) - @as(Vec2f, @splat(1.0));
    position = .{ ndc[0], ndc[1], 0.0, 1.0 };

    out_color.* = in_color.*;
    out_uv.* = in_uv.*;
    out_corner_radius.* = in_corner_radius.*;
    out_half_size.* = in_half_size.*;
    out_border_width.* = in_border_width.*;
    out_border_color.* = in_border_color.*;
    out_prim_type.* = in_prim_type.*;
}
