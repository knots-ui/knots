struct Viewport {
    size: vec2f,
}

@group(0) @binding(0)
var<uniform> viewport: Viewport;

@group(1) @binding(0)
var atlas_texture: texture_2d<f32>;

@group(1) @binding(1)
var atlas_sampler: sampler;

struct ClipNode {
    rect: vec4f,
    radii: vec4f,
    parent: u32,
    pad0: u32,
    pad1: u32,
    pad2: u32,
}

@group(2) @binding(0)
var<storage, read> clip_nodes: array<ClipNode>;

const MAX_CLIP_DEPTH: u32 = 32u;

struct VertexInput {
    @location(0) pos: vec2f,
    @location(1) uv: vec2f,
    @location(2) color: vec4f,
    @location(3) corner_radius: vec4f,
    @location(4) half_size: vec2f,
    @location(5) border_width: vec4f,
    @location(6) border_color: vec4f,
    @location(7) prim_type: f32,
    @location(8) clip_node: f32,
}

struct VertexOutput {
    @builtin(position) clip_pos: vec4f,
    @location(0) color: vec4f,
    @location(1) uv: vec2f,
    @location(2) corner_radius: vec4f,
    @location(3) half_size: vec2f,
    @location(4) border_width: vec4f,
    @location(5) border_color: vec4f,
    @location(6) prim_type: f32,
    @location(7) world_pos: vec2f,
    @location(8) clip_node: f32,
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
    out.world_pos = in.pos;
    out.clip_node = in.clip_node;
    return out;
}

struct InstanceInput {
    @location(0) pos: vec2f,
    @location(1) size: vec2f,
    @location(2) uv0: vec2f,
    @location(3) uv1: vec2f,
    @location(4) color: vec4f,
    @location(5) border_color: vec4f,
    @location(6) corner_radius: vec4f,
    @location(7) border_width: vec4f,
    @location(8) prim_type: f32,
    @location(9) clip_node: f32,
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
    out.world_pos = world;
    out.clip_node = inst.clip_node;

    if inst.prim_type < 0.5 {
        // SDF rect/circle: signed centered coords + half_size for sdRoundedBox.
        out.half_size = inst.size * 0.5;
        out.uv = inst.size * (corner - vec2f(0.5, 0.5));
    } else {
        // Text/image/raw vertex color: atlas UV interpolated where relevant.
        out.half_size = vec2f(0.0, 0.0);
        out.uv = mix(inst.uv0, inst.uv1, corner);
    }
    return out;
}

fn normalizedRadii(radii: vec4f, size: vec2f) -> vec4f {
    let r = max(radii, vec4f(0.0));
    var scale: f32 = 1.0;
    if (r.x + r.y > size.x && r.x + r.y > 0.0) {
        scale = min(scale, size.x / (r.x + r.y));
    }
    if (r.y + r.z > size.y && r.y + r.z > 0.0) {
        scale = min(scale, size.y / (r.y + r.z));
    }
    if (r.z + r.w > size.x && r.z + r.w > 0.0) {
        scale = min(scale, size.x / (r.z + r.w));
    }
    if (r.w + r.x > size.y && r.w + r.x > 0.0) {
        scale = min(scale, size.y / (r.w + r.x));
    }
    return r * scale;
}

fn cornerRadius(p: vec2f, radii: vec4f) -> f32 {
    if (p.y < 0.0) {
        if (p.x < 0.0) {
            return radii.x;
        }
        return radii.y;
    }
    if (p.x >= 0.0) {
        return radii.z;
    }
    return radii.w;
}

fn sdRoundedBox(p: vec2f, half_size: vec2f, radii: vec4f) -> f32 {
    let r = cornerRadius(p, normalizedRadii(radii, half_size * 2.0));
    let q = abs(p) - half_size + r;
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

fn innerRadii(radii: vec4f, width: vec4f) -> vec4f {
    return max(radii - vec4f(
        max(width.x, width.w),
        max(width.x, width.y),
        max(width.z, width.y),
        max(width.z, width.w),
    ), vec4f(0.0));
}

fn clipAlpha(world_pos: vec2f, clip_node: f32) -> f32 {
    var idx = u32(clip_node + 0.5);
    var alpha = 1.0;
    for (var i: u32 = 0u; i < MAX_CLIP_DEPTH && idx != 0u; i = i + 1u) {
        let node = clip_nodes[idx];
        let half_size = node.rect.zw * 0.5;
        let center = node.rect.xy + half_size;
        let d = sdRoundedBox(world_pos - center, half_size, node.radii);
        alpha = alpha * (1.0 - smoothstep(-0.5, 0.5, d));
        idx = node.parent;
    }
    if idx != 0u {
        return 0.0;
    }
    return alpha;
}

fn shadeLinear(in: VertexOutput) -> vec4f {
    let sampled = textureSample(atlas_texture, atlas_sampler, in.uv);

    if in.prim_type < 0.5 {
        let d = sdRoundedBox(in.uv, in.half_size, in.corner_radius);

        let fill_alpha = 1.0 - smoothstep(-0.5, 0.5, d);

        let width = max(in.border_width, vec4f(0.0));
        let max_width = max(max(width.x, width.y), max(width.z, width.w));
        var border_alpha = 0.0;
        if max_width > 0.0 {
            let inner_half_size = max(
                in.half_size - vec2f(width.w + width.y, width.x + width.z) * 0.5,
                vec2f(0.0),
            );
            let inner_center = vec2f(
                (width.w - width.y) * 0.5,
                (width.x - width.z) * 0.5,
            );
            let inner_d = sdRoundedBox(in.uv - inner_center, inner_half_size, innerRadii(in.corner_radius, width));
            let inner_alpha = 1.0 - smoothstep(-0.5, 0.5, inner_d);
            border_alpha = fill_alpha * (1.0 - inner_alpha);
        }

        let col = mix(in.color, in.border_color, border_alpha);
        let clip_alpha = clipAlpha(in.world_pos, in.clip_node);
        return vec4f(col.rgb, col.a * fill_alpha * clip_alpha);
    } else if in.prim_type < 1.5 {
        let coverage = sampled.r;
        let clip_alpha = clipAlpha(in.world_pos, in.clip_node);
        return vec4f(in.color.rgb, in.color.a * coverage * clip_alpha);
    } else if in.prim_type < 2.5 {
        let col = vec4f(sampled.rgb * in.color.rgb, sampled.a * in.color.a);
        return vec4f(col.rgb, col.a * clipAlpha(in.world_pos, in.clip_node));
    } else {
        return vec4f(in.color.rgb, in.color.a * clipAlpha(in.world_pos, in.clip_node));
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
