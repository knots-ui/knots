#version 450

layout(constant_id = 0) const bool apply_srgb_encode = false;

layout(set = 1, binding = 0) uniform texture2D atlas;
layout(set = 1, binding = 1) uniform sampler atlas_sampler;

layout(location = 0) in vec4 in_color;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_corner_radius;
layout(location = 3) in vec2 in_half_size;
layout(location = 4) in vec4 in_border_width;
layout(location = 5) in vec4 in_border_color;
layout(location = 6) in float in_prim_type;
layout(location = 7) in vec2 in_world_pos;
layout(location = 8) in float in_clip_node;

layout(location = 0) out vec4 frag_color;

const uint MAX_CLIP_DEPTH = 32u;

struct ClipNode {
    vec4 rect;
    vec4 radii;
    uint parent;
    uint pad0;
    uint pad1;
    uint pad2;
};

layout(set = 2, binding = 0, std430) readonly buffer ClipNodes {
    ClipNode clip_nodes[];
};

vec4 normalizedRadii(vec4 radii, vec2 size) {
    vec4 r = max(radii, vec4(0.0));
    float scale = 1.0;
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

float cornerRadius(vec2 p, vec4 radii) {
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

float sdRoundedBox(vec2 p, vec2 half_size, vec4 radii) {
    float radius = cornerRadius(p, normalizedRadii(radii, half_size * 2.0));
    vec2 q = abs(p) - half_size + radius;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

vec4 innerRadii(vec4 radii, vec4 width) {
    return max(radii - vec4(
        max(width.x, width.w),
        max(width.x, width.y),
        max(width.z, width.y),
        max(width.z, width.w)
    ), vec4(0.0));
}

float clipAlpha(vec2 world_pos, float clip_node) {
    uint idx = uint(clip_node + 0.5);
    float alpha = 1.0;
    for (uint i = 0u; i < MAX_CLIP_DEPTH && idx != 0u; i++) {
        ClipNode node = clip_nodes[idx];
        vec2 half_size = node.rect.zw * 0.5;
        vec2 center = node.rect.xy + half_size;
        float d = sdRoundedBox(world_pos - center, half_size, node.radii);
        alpha *= 1.0 - smoothstep(-0.5, 0.5, d);
        idx = node.parent;
    }
    return idx == 0u ? alpha : 0.0;
}

vec3 linearToSrgb(vec3 c) {
    bvec3 cutoff = lessThanEqual(c, vec3(0.0031308));
    vec3 lo = 12.92 * c;
    vec3 hi = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(hi, lo, vec3(cutoff));
}

void main() {
    vec4 sampled = texture(sampler2D(atlas, atlas_sampler), in_uv);
    vec4 col;
    if (in_prim_type < 0.5) {
        float d = sdRoundedBox(in_uv, in_half_size, in_corner_radius);

        float fill_alpha = 1.0 - smoothstep(-0.5, 0.5, d);

        vec4 width = max(in_border_width, vec4(0.0));
        float max_width = max(max(width.x, width.y), max(width.z, width.w));
        float border_alpha = 0.0;
        if (max_width > 0.0) {
            vec2 inner_half_size = max(
                in_half_size - vec2(width.w + width.y, width.x + width.z) * 0.5,
                vec2(0.0)
            );
            vec2 inner_center = vec2(
                (width.w - width.y) * 0.5,
                (width.x - width.z) * 0.5
            );
            float inner_d = sdRoundedBox(in_uv - inner_center, inner_half_size, innerRadii(in_corner_radius, width));
            float inner_alpha = 1.0 - smoothstep(-0.5, 0.5, inner_d);
            border_alpha = fill_alpha * (1.0 - inner_alpha);
        }

        vec4 mixed = mix(in_color, in_border_color, border_alpha);
        col = vec4(mixed.rgb, mixed.a * fill_alpha);
    } else if (in_prim_type < 1.5) {
        float coverage = sampled.r;
        col = vec4(in_color.rgb, in_color.a * coverage);
    } else if (in_prim_type < 2.5) {
        col = vec4(sampled.rgb * in_color.rgb, sampled.a * in_color.a);
    } else {
        col = in_color;
    }

    col.a *= clipAlpha(in_world_pos, in_clip_node);

    if (apply_srgb_encode) {
        frag_color = vec4(linearToSrgb(col.rgb), col.a);
    } else {
        frag_color = col;
    }
}
