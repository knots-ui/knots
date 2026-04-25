struct Viewport {
    size: vec2f,
}

@group(0) @binding(0)
var<uniform> viewport: Viewport;

@group(0) @binding(1)
var atlas_texture: texture_2d<f32>;

@group(0) @binding(2)
var atlas_sampler: sampler;

struct VertexInput {
    @location(0) pos: vec2f,
    @location(1) uv: vec2f,
    @location(2) color: vec4f,
    @location(3) corner_radius: f32,
    @location(4) half_size: vec2f,
    @location(5) border_width: f32,
    @location(6) border_color: vec4f,
    @location(7) prim_type: f32,
}

struct VertexOutput {
    @builtin(position) clip_pos: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
    @location(2) corner_radius: f32,
    @location(3) half_size: vec2f,
    @location(4) border_width: f32,
    @location(5) border_color: vec4f,
    @location(6) prim_type: f32,
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let ndc = (in.pos / viewport.size) * 2.0 - 1.0;

    var out: VertexOutput;
    out.clip_pos = vec4f(ndc.x, -ndc.y, 0.0, 1.0);
    out.color = in.color;
    out.uv = in.uv;
    out.corner_radius = in.corner_radius;
    out.half_size = in.half_size;
    out.border_width = in.border_width;
    out.border_color = in.border_color;
    out.prim_type = in.prim_type;
    return out;
}

struct InstanceInput {
    @location(0) pos: vec2f,
    @location(1) size: vec2f,
    @location(2) uv0: vec2f,
    @location(3) uv1: vec2f,
    @location(4) color: vec4f,
    @location(5) border_color: vec4f,
    @location(6) corner_radius: f32,
    @location(7) border_width: f32,
    @location(8) prim_type: f32,
    @location(9) _pad: f32,
}

@vertex
fn vs_instance_main(@builtin(vertex_index) vid: u32, inst: InstanceInput) -> VertexOutput {
    var corners = array<vec2f, 4>(
        vec2f(0.0, 0.0),
        vec2f(1.0, 0.0),
        vec2f(1.0, 1.0),
        vec2f(0.0, 1.0),
    );
    let corner = corners[vid];

    let world = inst.pos + inst.size * corner;
    let ndc = (world / viewport.size) * 2.0 - 1.0;

    var out: VertexOutput;
    out.clip_pos = vec4f(ndc.x, -ndc.y, 0.0, 1.0);
    out.color = inst.color;
    out.border_color = inst.border_color;
    out.corner_radius = inst.corner_radius;
    out.border_width = inst.border_width;
    out.prim_type = inst.prim_type;

    if inst.prim_type < 0.5 {
        // SDF rect/circle: signed centered coords + half_size for sdRoundedBox.
        out.half_size = inst.size * 0.5;
        out.uv = inst.size * (corner - vec2f(0.5, 0.5));
    } else {
        // Text/image: atlas UV interpolated across the quad.
        out.half_size = vec2f(0.0, 0.0);
        out.uv = mix(inst.uv0, inst.uv1, corner);
    }
    return out;
}

fn sdRoundedBox(p: vec2f, half_size: vec2f, radius: f32) -> f32 {
    let q = abs(p) - half_size + radius;
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

fn shadeLinear(in: VertexOutput) -> vec4f {
    let sampled = textureSample(atlas_texture, atlas_sampler, in.uv);

    if in.prim_type < 0.5 {
        let d = sdRoundedBox(in.uv, in.half_size, in.corner_radius);

        let fill_alpha = 1.0 - smoothstep(-0.5, 0.5, d);

        let border_d = abs(d) - in.border_width;
        let border_alpha = 1.0 - smoothstep(-0.5, 0.5, border_d);

        let col = mix(in.color, in.border_color, border_alpha * fill_alpha);
        return vec4f(col.rgb, col.a * fill_alpha);
    } else if in.prim_type < 1.5 {
        let coverage = sampled.r;
        return vec4f(in.color.rgb, in.color.a * coverage);
    } else {
        return vec4f(sampled.rgb * in.color.rgb, in.color.a);
    }
}

fn linearToSrgb(c: vec3f) -> vec3f {
    let cutoff = c <= vec3f(0.0031308);
    let lo = 12.92 * c;
    let hi = 1.055 * pow(c, vec3f(1.0 / 2.4)) - 0.055;
    return select(hi, lo, cutoff);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return shadeLinear(in);
}

@fragment
fn fs_main_srgb_encode(in: VertexOutput) -> @location(0) vec4f {
    let c = shadeLinear(in);
    return vec4f(linearToSrgb(c.rgb), c.a);
}
