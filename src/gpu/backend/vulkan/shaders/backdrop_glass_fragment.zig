const common = @import("common.zig");

const Vec4f = common.Vec4f;
const Vec2f = common.Vec2f;
const uniformConstant = common.uniformConstant;
const storageBuffer = common.storageBuffer;
const input = common.input;
const output = common.output;

const source = uniformConstant(common.Image2D(f32), "source", .{ .descriptor = .{ .set = 1, .binding = 0 } });
const source_sampler = uniformConstant(common.Sampler, "source_sampler", .{ .descriptor = .{ .set = 1, .binding = 1 } });
const clip_nodes = storageBuffer(common.ClipNodes, "clip_nodes", .{ .descriptor = .{ .set = 2, .binding = 0 } });

const in_local = input(Vec2f, "in_local", .{ .location = 0 });
const in_half_size = input(Vec2f, "in_half_size", .{ .location = 1 });
const in_corner_radius = input(Vec4f, "in_corner_radius", .{ .location = 2 });
const in_sample_uv = input(Vec2f, "in_sample_uv", .{ .location = 3 });
const in_world_pos = input(Vec2f, "in_world_pos", .{ .location = 4 });
const in_params = input(Vec4f, "in_params", .{ .location = 5 });
const in_uv_per_logical = input(Vec2f, "in_uv_per_logical", .{ .location = 6 });
const in_optics = input(Vec4f, "in_optics", .{ .location = 7 });

const frag_color = output(Vec4f, "frag_color", .{ .location = 0 });

const ior: f32 = 1.5;

/// Lateral shift of a vertical ray refracted by the rim, normalized to 1 at the
/// outer edge. `x` runs 0 at the edge to 1 where the bezel meets the flat top;
/// the surface there is Apple's convex squircle, h(x) = (1 - (1 - x)^4)^(1/4).
fn refractionProfile(x: f32) f32 {
    const u = 1.0 - common.clamp(x, 0.0, 1.0);
    const run = u * u * u;
    const rise = @exp(@log(@max(1.0 - u * u * u * u, 1e-6)) * 0.75);
    const inv = 1.0 / @sqrt(run * run + rise * rise);
    const sin_in = run * inv;
    const cos_in = rise * inv;
    const sin_out = sin_in / ior;
    const cos_out = @sqrt(1.0 - sin_out * sin_out);
    const shift = (sin_in * cos_out - cos_in * sin_out) / @max(cos_in * cos_out + sin_in * sin_out, 1e-4);
    return shift / @sqrt(ior * ior - 1.0);
}

fn sd(p: Vec2f) f32 {
    return common.sdRoundedBox(p, in_half_size.*, in_corner_radius.*);
}

fn tap(uv: Vec2f) Vec4f {
    return common.sampleImplicitLod2Df(source, source_sampler, uv);
}

fn scale2(v: Vec2f, s: f32) Vec2f {
    return v * @as(Vec2f, @splat(s));
}

/// Pass-through: the source holds the scene's stored encoding, so no conversion.
export fn fs_glass() callconv(.{ .spirv_fragment = .{} }) void {
    const local = in_local.*;
    const params = in_params.*;
    const optics = in_optics.*;
    const d = sd(local);
    const coverage = 1.0 - common.smoothstep(-0.5, 0.5, d);

    // Outward edge normal from the distance field's gradient.
    const gradient = Vec2f{
        sd(local + Vec2f{ 0.5, 0.0 }) - sd(local - Vec2f{ 0.5, 0.0 }),
        sd(local + Vec2f{ 0.0, 0.5 }) - sd(local - Vec2f{ 0.0, 0.5 }),
    };
    const length = @max(@sqrt(gradient[0] * gradient[0] + gradient[1] * gradient[1]), 1e-5);
    const normal = scale2(gradient, 1.0 / length);

    const bezel = optics[1];
    const x = if (bezel > 0.0) -d / bezel else 1.0;
    // Sample inward so content under the rim is magnified outward.
    const shift = scale2(normal, optics[0] * refractionProfile(x)) * in_uv_per_logical.*;
    const spread = optics[2];
    const uv = in_sample_uv.*;
    const red = tap(uv - scale2(shift, 1.0 + spread));
    const green = tap(uv - shift);
    const blue = tap(uv - scale2(shift, 1.0 - spread));

    const saturation = params[0];
    const luma = red[0] * 0.2126 + green[1] * 0.7152 + blue[2] * 0.0722;
    var color = Vec4f{
        luma + (red[0] - luma) * saturation,
        luma + (green[1] - luma) * saturation,
        luma + (blue[2] - luma) * saturation,
        0.0,
    };

    // Rim highlight, strongest on edges facing the top-left light.
    const rim = 1.0 - common.clamp(x, 0.0, 1.0);
    const facing = @abs(normal[0] * -0.70710678 + normal[1] * -0.70710678);
    const highlight = common.clamp(optics[3] * rim * rim * rim * (0.3 + 0.7 * facing), 0.0, 1.0);
    color += (@as(Vec4f, @splat(1.0)) - color) * @as(Vec4f, @splat(highlight));

    color[3] = coverage * common.clipAlpha(clip_nodes, in_world_pos.*, params[1]);
    frag_color.* = color;
}
