#version 450

layout(set = 0, binding = 0) uniform Viewport {
    vec2 size;
} viewport;

layout(location = 0) in vec2 in_pos;
layout(location = 1) in vec2 in_size;
layout(location = 2) in vec2 in_uv0;
layout(location = 3) in vec2 in_uv1;
layout(location = 4) in vec4 in_color;
layout(location = 5) in vec4 in_border_color;
layout(location = 6) in float in_corner_radius;
layout(location = 7) in float in_border_width;
layout(location = 8) in float in_prim_type;
layout(location = 9) in float in_pad;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_uv;
layout(location = 2) out float out_corner_radius;
layout(location = 3) out vec2 out_half_size;
layout(location = 4) out float out_border_width;
layout(location = 5) out vec4 out_border_color;
layout(location = 6) out float out_prim_type;

const vec2 CORNERS[4] = vec2[4](
    vec2(0.0, 0.0),
    vec2(1.0, 0.0),
    vec2(1.0, 1.0),
    vec2(0.0, 1.0)
);

void main() {
    vec2 corner = CORNERS[gl_VertexIndex];
    vec2 world = in_pos + in_size * corner;
    vec2 ndc = (world / viewport.size) * 2.0 - 1.0;
    gl_Position = vec4(ndc.x, ndc.y, 0.0, 1.0);

    out_color = in_color;
    out_border_color = in_border_color;
    out_corner_radius = in_corner_radius;
    out_border_width = in_border_width;
    out_prim_type = in_prim_type;

    if (in_prim_type < 0.5) {
        out_half_size = in_size * 0.5;
        out_uv = in_size * (corner - vec2(0.5));
    } else {
        out_half_size = vec2(0.0);
        out_uv = mix(in_uv0, in_uv1, corner);
    }
    // Discard pad to avoid unused-input warnings.
    out_uv += vec2(0.0) * in_pad;
}
