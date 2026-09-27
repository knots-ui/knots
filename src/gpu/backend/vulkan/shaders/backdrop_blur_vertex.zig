const gpu = @import("std").spirv;

const Vec4f = @import("common.zig").Vec4f;
const Vec2f = @import("common.zig").Vec2f;
const input = @import("common.zig").input;
const output = @import("common.zig").output;

/// In source UV: region origin and extent, tap clamp, and tap distance.
const in_source = input(Vec4f, "in_source", .{ .location = 0 });
const in_bounds = input(Vec4f, "in_bounds", .{ .location = 1 });
const in_tap = input(Vec2f, "in_tap", .{ .location = 2 });

const out_uv = output(Vec2f, "out_uv", .{ .location = 0 });
const out_half_pixel = output(Vec2f, "out_half_pixel", .{ .location = 1 });
const out_bounds = output(Vec4f, "out_bounds", .{ .location = 2 });

extern var position: Vec4f addrspace(.output);

/// One triangle covering the viewport, which is the destination level's region.
/// Vulkan clip space is y-down, like texture space.
export fn main() callconv(.spirv_vertex) void {
    const idx = gpu.vertex_index;
    const uv = Vec2f{ if (idx == 1) 2.0 else 0.0, if (idx == 2) 2.0 else 0.0 };
    position = .{ uv[0] * 2.0 - 1.0, uv[1] * 2.0 - 1.0, 0.0, 1.0 };
    const source = in_source.*;
    out_uv.* = Vec2f{ source[0], source[1] } + uv * Vec2f{ source[2], source[3] };
    out_half_pixel.* = in_tap.*;
    out_bounds.* = in_bounds.*;
}
