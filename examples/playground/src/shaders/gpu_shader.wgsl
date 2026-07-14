struct Uniforms {
    viewport: vec4f,
    camera: vec4f,
    geometry: vec4f,
    clip_transform: vec4f,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct VertexInput {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
    @location(2) particle: vec4f,
};

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) normal: vec3f,
    @location(1) view_position: vec3f,
    @location(2) phase: f32,
};

const TAU: f32 = 6.28318530718;

fn knotPoint(t: f32) -> vec3f {
    let ring = 1.18 + 0.52 * cos(4.0 * t);
    return vec3f(ring * cos(3.0 * t), 0.52 * sin(4.0 * t), ring * sin(3.0 * t));
}

fn rotateY(value: vec3f, angle: f32) -> vec3f {
    let c = cos(angle);
    let s = sin(angle);
    return vec3f(c * value.x + s * value.z, value.y, -s * value.x + c * value.z);
}

fn rotateX(value: vec3f, angle: f32) -> vec3f {
    let c = cos(angle);
    let s = sin(angle);
    return vec3f(value.x, c * value.y - s * value.z, s * value.y + c * value.z);
}

@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    let t = input.particle.x * TAU;
    let centerline = knotPoint(t);
    let tangent = normalize(knotPoint(t + 0.002) - knotPoint(t - 0.002));
    let guide = select(vec3f(0.0, 1.0, 0.0), vec3f(1.0, 0.0, 0.0), abs(tangent.y) > 0.9);
    let side = normalize(cross(guide, tangent));
    let up = cross(tangent, side);

    let radial_angle = input.particle.y + uniforms.viewport.w * t +
        uniforms.viewport.z * (0.12 + input.particle.w * 0.08);
    let radial_direction = side * cos(radial_angle) + up * sin(radial_angle);
    let center = centerline + radial_direction * uniforms.geometry.x * input.particle.z;
    let particle_scale = 0.032 * uniforms.geometry.y * uniforms.geometry.z *
        (0.62 + input.particle.w * 0.76);
    let local_position = side * input.position.x + up * input.position.y + tangent * input.position.z;
    let local_normal = side * input.normal.x + up * input.normal.y + tangent * input.normal.z;

    let yawed_position = rotateY(center + local_position * particle_scale, uniforms.camera.x);
    let view_position = rotateX(yawed_position, uniforms.camera.y) +
        vec3f(0.0, 0.0, 4.8 / uniforms.camera.z);
    let view_normal = rotateX(rotateY(local_normal, uniforms.camera.x), uniforms.camera.y);
    let aspect = uniforms.viewport.x / max(uniforms.viewport.y, 1.0);
    let focal = 1.0 / uniforms.camera.w;

    var output: VertexOutput;
    let clip_position = vec4f(
        view_position.x * focal / aspect,
        view_position.y * focal,
        view_position.z - 0.1,
        view_position.z,
    );
    output.position = vec4f(
        clip_position.x * uniforms.clip_transform.x + clip_position.w * uniforms.clip_transform.z,
        clip_position.y * uniforms.clip_transform.y + clip_position.w * uniforms.clip_transform.w,
        clip_position.z,
        clip_position.w,
    );
    output.normal = view_normal;
    output.view_position = view_position;
    output.phase = input.particle.x;
    return output;
}

@fragment
fn fs_main(input: VertexOutput) -> @location(0) vec4f {
    let normal = normalize(input.normal);
    let view_direction = normalize(-input.view_position);
    let light_direction = normalize(vec3f(-0.45, 0.72, -0.9));
    let diffuse = max(dot(normal, light_direction), 0.0);
    let rim_base = 1.0 - abs(dot(normal, view_direction));
    let rim = rim_base * rim_base;
    let depth_fade = clamp(1.38 - input.view_position.z * 0.17, 0.28, 1.0);
    let shimmer = 0.82 + 0.18 * sin(uniforms.viewport.z * 1.8 + input.phase * 37.0);
    let cyan = vec3f(0.12, 0.82, 1.0);
    let violet = vec3f(0.48, 0.28, 1.0);
    let white = vec3f(0.82, 0.96, 1.0);
    let base = mix(cyan, violet, 0.5 + 0.5 * sin(input.phase * TAU * 3.0));
    let color = mix(base, white, diffuse * 0.52 + rim * 0.34);
    let emission = color * (0.026 + diffuse * 0.055 + rim * 0.082) * depth_fade * shimmer * uniforms.geometry.w;
    return vec4f(emission, 0.0);
}
