const common = @import("common.zig");

const Vec4f = common.Vec4f;
const Vec2f = common.Vec2f;
const uniformConstant = common.uniformConstant;
const input = common.input;
const output = common.output;

const source = uniformConstant(common.Image2D(f32), "source", .{ .descriptor = .{ .set = 1, .binding = 0 } });
const source_sampler = uniformConstant(common.Sampler, "source_sampler", .{ .descriptor = .{ .set = 1, .binding = 1 } });

const in_uv = input(Vec2f, "in_uv", .{ .location = 0 });
const in_half_pixel = input(Vec2f, "in_half_pixel", .{ .location = 1 });
const in_bounds = input(Vec4f, "in_bounds", .{ .location = 2 });

const frag_color = output(Vec4f, "frag_color", .{ .location = 0 });

fn tap(uv: Vec2f) Vec4f {
    const bounds = in_bounds.*;
    const clamped = Vec2f{
        common.clamp(uv[0], bounds[0], bounds[2]),
        common.clamp(uv[1], bounds[1], bounds[3]),
    };
    return common.sampleImplicitLod2Df(source, source_sampler, clamped);
}

fn scale(v: Vec4f, s: f32) Vec4f {
    return v * @as(Vec4f, @splat(s));
}

/// Dual Kawase (Bjørge, SIGGRAPH 2015) downsample.
export fn fs_blur_down() callconv(.{ .spirv_fragment = .{} }) void {
    const uv = in_uv.*;
    const h = in_half_pixel.*;
    var sum = scale(tap(uv), 4.0);
    sum += tap(uv - h);
    sum += tap(uv + h);
    sum += tap(uv + Vec2f{ h[0], -h[1] });
    sum += tap(uv - Vec2f{ h[0], -h[1] });
    frag_color.* = scale(sum, 1.0 / 8.0);
}

/// Dual Kawase upsample.
export fn fs_blur_up() callconv(.{ .spirv_fragment = .{} }) void {
    const uv = in_uv.*;
    const h = in_half_pixel.*;
    var sum = tap(uv + Vec2f{ -h[0] * 2.0, 0.0 });
    sum += scale(tap(uv + Vec2f{ -h[0], h[1] }), 2.0);
    sum += tap(uv + Vec2f{ 0.0, h[1] * 2.0 });
    sum += scale(tap(uv + Vec2f{ h[0], h[1] }), 2.0);
    sum += tap(uv + Vec2f{ h[0] * 2.0, 0.0 });
    sum += scale(tap(uv + Vec2f{ h[0], -h[1] }), 2.0);
    sum += tap(uv + Vec2f{ 0.0, -h[1] * 2.0 });
    sum += scale(tap(uv + Vec2f{ -h[0], -h[1] }), 2.0);
    frag_color.* = scale(sum, 1.0 / 12.0);
}
