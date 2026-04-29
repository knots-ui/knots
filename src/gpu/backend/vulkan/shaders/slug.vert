// glsl port of the Slug analytic font rendering algorithm.
// Reference: https://github.com/EricLengyel/Slug/tree/main

#version 450

layout(set = 0, binding = 0) uniform Uniforms {
    vec4 mvp_row0;
    vec4 mvp_row1;
    vec4 mvp_row2;
    vec4 mvp_row3;
    vec4 viewport;
} u;

layout(location = 0) in vec4 in_pos;
layout(location = 1) in vec4 in_tex;
layout(location = 2) in vec4 in_jac;
layout(location = 3) in vec4 in_bnd;
layout(location = 4) in vec4 in_col;

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec2 out_texcoord;
layout(location = 2) flat out vec4 out_banding;
layout(location = 3) flat out ivec4 out_glyph;

vec4 slug_dilate(vec4 pos, vec4 tex, vec4 jac, vec4 m0, vec4 m1, vec4 m3, vec2 dim) {
    vec2 n = normalize(pos.zw);
    float s = dot(m3.xy, pos.xy) + m3.w;
    float t = dot(m3.xy, n);

    float u_ = (s * dot(m0.xy, n) - t * (dot(m0.xy, pos.xy) + m0.w)) * dim.x;
    float v_ = (s * dot(m1.xy, n) - t * (dot(m1.xy, pos.xy) + m1.w)) * dim.y;

    float s2 = s * s;
    float st = s * t;
    float uv = u_ * u_ + v_ * v_;
    float denom = max(uv - st * st, 1.0e-12);
    vec2 d = pos.zw * (s2 * (st + sqrt(uv)) / denom);

    vec2 vpos = pos.xy + d;
    vec2 vtex = vec2(tex.x + dot(d, jac.xy), tex.y + dot(d, jac.zw));
    return vec4(vpos, vtex);
}

ivec4 unpack_glyph(vec4 tex) {
    uint zb = floatBitsToUint(tex.z);
    uint wb = floatBitsToUint(tex.w);
    return ivec4(int(zb & 0xFFFFu), int(zb >> 16u), int(wb & 0xFFFFu), int(wb >> 16u));
}

void main() {
    vec4 dilated = slug_dilate(in_pos, in_tex, in_jac, u.mvp_row0, u.mvp_row1, u.mvp_row3, u.viewport.xy);
    vec2 p = dilated.xy;

    gl_Position = vec4(
            p.x * u.mvp_row0.x + p.y * u.mvp_row0.y + u.mvp_row0.w,
            p.x * u.mvp_row1.x + p.y * u.mvp_row1.y + u.mvp_row1.w,
            p.x * u.mvp_row2.x + p.y * u.mvp_row2.y + u.mvp_row2.w,
            p.x * u.mvp_row3.x + p.y * u.mvp_row3.y + u.mvp_row3.w
        );
    out_texcoord = dilated.zw;
    out_banding = in_bnd;
    out_glyph = unpack_glyph(in_tex);
    out_color = in_col;
}
