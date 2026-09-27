const gpu = @import("std").spirv;

const Vec4f = @import("common.zig").Vec4f;
const Vec2f = @import("common.zig").Vec2f;
const uniform = @import("common.zig").uniform;
const input = @import("common.zig").input;
const output = @import("common.zig").output;

const Viewport = extern struct { size: Vec2f };

const viewport = uniform(Viewport, "viewport", .{ .descriptor = .{ .set = 0, .binding = 0 } });

const in_rect = input(Vec4f, "in_rect", .{ .location = 0 });
const in_corner_radius = input(Vec4f, "in_corner_radius", .{ .location = 1 });
/// xy = logical origin of the filtered region, zw = its UV per logical pixel.
const in_sample_map = input(Vec4f, "in_sample_map", .{ .location = 2 });
/// x = saturation, y = clip node.
const in_params = input(Vec4f, "in_params", .{ .location = 3 });
/// x = refraction, y = bezel, z = dispersion, w = specular.
const in_optics = input(Vec4f, "in_optics", .{ .location = 4 });

const out_local = output(Vec2f, "out_local", .{ .location = 0 });
const out_half_size = output(Vec2f, "out_half_size", .{ .location = 1 });
const out_corner_radius = output(Vec4f, "out_corner_radius", .{ .location = 2 });
const out_sample_uv = output(Vec2f, "out_sample_uv", .{ .location = 3 });
const out_world_pos = output(Vec2f, "out_world_pos", .{ .location = 4 });
const out_params = output(Vec4f, "out_params", .{ .location = 5 });
const out_uv_per_logical = output(Vec2f, "out_uv_per_logical", .{ .location = 6 });
const out_optics = output(Vec4f, "out_optics", .{ .location = 7 });

extern var position: Vec4f addrspace(.output);

export fn main() callconv(.spirv_vertex) void {
    const idx = gpu.vertex_index;
    const cx: f32 = if (idx == 1 or idx == 2) 1.0 else 0.0;
    const cy: f32 = if (idx == 2 or idx == 3) 1.0 else 0.0;
    const rect = in_rect.*;
    const origin = Vec2f{ rect[0], rect[1] };
    const size = Vec2f{ rect[2], rect[3] };

    const world = origin + size * Vec2f{ cx, cy };
    const ndc = (world / viewport.*.size) * @as(Vec2f, @splat(2.0)) - @as(Vec2f, @splat(1.0));
    position = .{ ndc[0], ndc[1], 0.0, 1.0 };

    const half_size = size * @as(Vec2f, @splat(0.5));
    const sample = in_sample_map.*;
    out_half_size.* = half_size;
    out_local.* = world - origin - half_size;
    out_corner_radius.* = in_corner_radius.*;
    out_sample_uv.* = (world - Vec2f{ sample[0], sample[1] }) * Vec2f{ sample[2], sample[3] };
    out_world_pos.* = world;
    out_params.* = in_params.*;
    out_uv_per_logical.* = .{ sample[2], sample[3] };
    out_optics.* = in_optics.*;
}
