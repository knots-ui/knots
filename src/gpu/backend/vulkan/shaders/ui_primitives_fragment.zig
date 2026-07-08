const common = @import("common.zig");

const Vec4f = common.Vec4f;
const Vec3f = common.Vec3f;
const Vec2f = common.Vec2f;
const uniformConstant = common.uniformConstant;
const storageBuffer = common.storageBuffer;
const input = common.input;
const output = common.output;

const atlas = uniformConstant(common.Image2D(f32), "atlas", .{ .descriptor = .{ .set = 1, .binding = 0 } });
const atlas_sampler = uniformConstant(common.Sampler, "atlas_sampler", .{ .descriptor = .{ .set = 1, .binding = 1 } });
const clip_nodes = storageBuffer(common.ClipNodes, "clip_nodes", .{ .descriptor = .{ .set = 2, .binding = 0 } });

const in_color = input(Vec4f, "in_color", .{ .location = 0 });
const in_uv = input(Vec2f, "in_uv", .{ .location = 1 });
const in_corner_radius = input(Vec4f, "in_corner_radius", .{ .location = 2 });
const in_half_size = input(Vec2f, "in_half_size", .{ .location = 3 });
const in_border_width = input(Vec4f, "in_border_width", .{ .location = 4 });
const in_border_color = input(Vec4f, "in_border_color", .{ .location = 5 });
const in_prim_type = input(f32, "in_prim_type", .{ .location = 6 });
const in_world_pos = input(Vec2f, "in_world_pos", .{ .location = 7 });
const in_clip_node = input(f32, "in_clip_node", .{ .location = 8 });

const frag_color = output(Vec4f, "frag_color", .{ .location = 0 });

fn innerRadii(radii: Vec4f, width: Vec4f) Vec4f {
    return @max(radii - Vec4f{
        @max(width[0], width[3]),
        @max(width[0], width[1]),
        @max(width[2], width[1]),
        @max(width[2], width[3]),
    }, @as(Vec4f, @splat(0.0)));
}

fn mix4(a: Vec4f, b: Vec4f, t: f32) Vec4f {
    return a * @as(Vec4f, @splat(1.0 - t)) + b * @as(Vec4f, @splat(t));
}

fn fragment(comptime encode_srgb: bool) void {
    const color = in_color.*;
    const sampled = common.sampleImplicitLod2Df(atlas, atlas_sampler, in_uv.*);

    const col = if (in_prim_type.* < 0.5) blk: {
        const d = common.sdRoundedBox(in_uv.*, in_half_size.*, in_corner_radius.*);
        const fill_alpha = 1.0 - common.smoothstep(-0.5, 0.5, d);

        const width = @max(in_border_width.*, @as(Vec4f, @splat(0.0)));
        const max_width = @max(@max(width[0], width[1]), @max(width[2], width[3]));
        var border_alpha: f32 = 0.0;
        if (max_width > 0.0) {
            const inner_half_size = @max(
                in_half_size.* - Vec2f{ width[3] + width[1], width[0] + width[2] } * @as(Vec2f, @splat(0.5)),
                @as(Vec2f, @splat(0.0)),
            );
            const inner_center = Vec2f{
                (width[3] - width[1]) * 0.5,
                (width[0] - width[2]) * 0.5,
            };
            const inner_d = common.sdRoundedBox(in_uv.* - inner_center, inner_half_size, innerRadii(in_corner_radius.*, width));
            const inner_alpha = 1.0 - common.smoothstep(-0.5, 0.5, inner_d);
            border_alpha = fill_alpha * (1.0 - inner_alpha);
        }

        const mixed = mix4(color, in_border_color.*, border_alpha);
        break :blk .{ mixed[0], mixed[1], mixed[2], mixed[3] * fill_alpha };
    } else if (in_prim_type.* < 1.5) blk: {
        const coverage = sampled[0];
        break :blk .{ color[0], color[1], color[2], color[3] * coverage };
    } else if (in_prim_type.* < 2.5)
        .{ sampled[0] * color[0], sampled[1] * color[1], sampled[2] * color[2], sampled[3] * color[3] }
    else
        color;

    const alpha = col[3] * common.clipAlpha(clip_nodes, in_world_pos.*, in_clip_node.*);
    if (comptime encode_srgb) {
        const srgb = common.linearToSrgb(Vec3f{ col[0], col[1], col[2] });
        frag_color.* = .{ srgb[0], srgb[1], srgb[2], alpha };
    } else frag_color.* = .{ col[0], col[1], col[2], alpha };
}

export fn fs_main() callconv(.{ .spirv_fragment = .{} }) void {
    fragment(false);
}

export fn fs_main_srgb_encode() callconv(.{ .spirv_fragment = .{} }) void {
    fragment(true);
}
