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
const in_normal = common.input(Vec3f, "in_normal", .{ .location = 0 });
const in_view_position = common.input(Vec3f, "in_view_position", .{ .location = 1 });
const in_phase = common.input(f32, "in_phase", .{ .location = 2 });
const frag_color = common.output(Vec4f, "frag_color", .{ .location = 0 });

const tau: f32 = 6.28318530718;

fn dot3(a: Vec3f, b: Vec3f) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn normalize3(value: Vec3f) Vec3f {
    const len = @sqrt(@max(dot3(value, value), 0.00000001));
    return value / @as(Vec3f, @splat(len));
}

fn mix3(a: Vec3f, b: Vec3f, t: f32) Vec3f {
    return a * @as(Vec3f, @splat(1.0 - t)) + b * @as(Vec3f, @splat(t));
}

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    const normal = normalize3(in_normal.*);
    const view_direction = normalize3(-in_view_position.*);
    const light_direction = normalize3(.{ -0.45, 0.72, -0.9 });
    const diffuse = @max(dot3(normal, light_direction), 0.0);
    const rim_base = 1.0 - @abs(dot3(normal, view_direction));
    const rim = rim_base * rim_base;
    const depth_fade = common.clamp(1.38 - in_view_position.*[2] * 0.17, 0.28, 1.0);
    const shimmer = 0.82 + 0.18 * @sin(uniforms.*.viewport[2] * 1.8 + in_phase.* * 37.0);
    const cyan = Vec3f{ 0.12, 0.82, 1.0 };
    const violet = Vec3f{ 0.48, 0.28, 1.0 };
    const white = Vec3f{ 0.82, 0.96, 1.0 };
    const base = mix3(cyan, violet, 0.5 + 0.5 * @sin(in_phase.* * tau * 3.0));
    const color = mix3(base, white, diffuse * 0.52 + rim * 0.34);
    const intensity = (0.026 + diffuse * 0.055 + rim * 0.082) * depth_fade * shimmer * uniforms.*.geometry[3];
    const emission = color * @as(Vec3f, @splat(intensity));
    frag_color.* = .{ emission[0], emission[1], emission[2], 0.0 };
}
