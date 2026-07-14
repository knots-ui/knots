const common = @import("shader_common");

const Vec3f = common.Vec3f;
const Vec4f = common.Vec4f;

const Uniforms = extern struct {
    viewport: Vec4f,
    camera: Vec4f,
    geometry: Vec4f,
    clip_transform: Vec4f,
};

const uniforms = common.uniform(Uniforms, "uniforms", .{ .descriptor = .{ .set = 0, .binding = 0 } });
const in_position = common.input(Vec3f, "in_position", .{ .location = 0 });
const in_normal = common.input(Vec3f, "in_normal", .{ .location = 1 });
const in_particle = common.input(Vec4f, "in_particle", .{ .location = 2 });
const out_normal = common.output(Vec3f, "out_normal", .{ .location = 0 });
const out_view_position = common.output(Vec3f, "out_view_position", .{ .location = 1 });
const out_phase = common.output(f32, "out_phase", .{ .location = 2 });
extern var position: Vec4f addrspace(.output);

const tau: f32 = 6.28318530718;

fn dot3(a: Vec3f, b: Vec3f) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn normalize3(value: Vec3f) Vec3f {
    const len = @sqrt(@max(dot3(value, value), 0.00000001));
    return value / @as(Vec3f, @splat(len));
}

fn cross3(a: Vec3f, b: Vec3f) Vec3f {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn knotPoint(t: f32) Vec3f {
    const ring = 1.18 + 0.52 * @cos(4.0 * t);
    return .{ ring * @cos(3.0 * t), 0.52 * @sin(4.0 * t), ring * @sin(3.0 * t) };
}

fn rotateY(value: Vec3f, angle: f32) Vec3f {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ c * value[0] + s * value[2], value[1], -s * value[0] + c * value[2] };
}

fn rotateX(value: Vec3f, angle: f32) Vec3f {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{ value[0], c * value[1] - s * value[2], s * value[1] + c * value[2] };
}

export fn main() callconv(.spirv_vertex) void {
    const t = in_particle.*[0] * tau;
    const centerline = knotPoint(t);
    const tangent = normalize3(knotPoint(t + 0.002) - knotPoint(t - 0.002));
    const guide: Vec3f = if (@abs(tangent[1]) > 0.9) .{ 1.0, 0.0, 0.0 } else .{ 0.0, 1.0, 0.0 };
    const side = normalize3(cross3(guide, tangent));
    const up = cross3(tangent, side);

    const radial_angle = in_particle.*[1] + uniforms.*.viewport[3] * t +
        uniforms.*.viewport[2] * (0.12 + in_particle.*[3] * 0.08);
    const radial_direction = side * @as(Vec3f, @splat(@cos(radial_angle))) +
        up * @as(Vec3f, @splat(@sin(radial_angle)));
    const center = centerline + radial_direction * @as(Vec3f, @splat(uniforms.*.geometry[0] * in_particle.*[2]));
    const particle_scale = 0.032 * uniforms.*.geometry[1] * uniforms.*.geometry[2] * (0.62 + in_particle.*[3] * 0.76);
    const local_position = side * @as(Vec3f, @splat(in_position.*[0])) +
        up * @as(Vec3f, @splat(in_position.*[1])) +
        tangent * @as(Vec3f, @splat(in_position.*[2]));
    const local_normal = side * @as(Vec3f, @splat(in_normal.*[0])) +
        up * @as(Vec3f, @splat(in_normal.*[1])) +
        tangent * @as(Vec3f, @splat(in_normal.*[2]));

    const yawed_position = rotateY(center + local_position * @as(Vec3f, @splat(particle_scale)), uniforms.*.camera[0]);
    const view_position = rotateX(yawed_position, uniforms.*.camera[1]) + Vec3f{ 0.0, 0.0, 4.8 / uniforms.*.camera[2] };
    const view_normal = rotateX(rotateY(local_normal, uniforms.*.camera[0]), uniforms.*.camera[1]);
    const aspect = uniforms.*.viewport[0] / @max(uniforms.*.viewport[1], 1.0);
    const focal = 1.0 / uniforms.*.camera[3];

    const clip_position = Vec4f{
        view_position[0] * focal / aspect,
        -view_position[1] * focal,
        view_position[2] - 0.1,
        view_position[2],
    };
    position = .{
        clip_position[0] * uniforms.*.clip_transform[0] + clip_position[3] * uniforms.*.clip_transform[2],
        clip_position[1] * uniforms.*.clip_transform[1] + clip_position[3] * uniforms.*.clip_transform[3],
        clip_position[2],
        clip_position[3],
    };
    out_normal.* = view_normal;
    out_view_position.* = view_position;
    out_phase.* = in_particle.*[0];
}
