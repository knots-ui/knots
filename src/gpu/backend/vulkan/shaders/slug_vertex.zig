//! Zig port of the Slug analytic font rendering algorithm.
//! Reference: https://github.com/EricLengyel/Slug/tree/main

const Vec4f = @import("common.zig").Vec4f;
const Vec2f = @import("common.zig").Vec2f;
const uniform = @import("common.zig").uniform;
const input = @import("common.zig").input;
const output = @import("common.zig").output;

const Uniforms = extern struct {
    mvp_row0: Vec4f,
    mvp_row1: Vec4f,
    mvp_row2: Vec4f,
    mvp_row3: Vec4f,
    viewport: Vec4f,
};

const u = uniform(Uniforms, "u", .{ .descriptor = .{ .set = 0, .binding = 0 } });

const in_pos = input(Vec4f, "in_pos", .{ .location = 0 });
const in_tex = input(Vec4f, "in_tex", .{ .location = 1 });
const in_jac = input(Vec4f, "in_jac", .{ .location = 2 });
const in_bnd = input(Vec4f, "in_bnd", .{ .location = 3 });
const in_col = input(Vec4f, "in_col", .{ .location = 4 });
const in_clip_node = input(f32, "in_clip_node", .{ .location = 5 });

const out_color = output(Vec4f, "out_color", .{ .location = 0 });
const out_texcoord = output(Vec2f, "out_texcoord", .{ .location = 1 });
const out_banding = output(Vec4f, "out_banding", .{ .location = 2 });
const out_glyph = output(@Vector(4, i32), "out_glyph", .{ .location = 3 });
const out_world_pos = output(Vec2f, "out_world_pos", .{ .location = 4 });
const out_clip_node = output(f32, "out_clip_node", .{ .location = 5 });

extern var position: Vec4f addrspace(.output);

inline fn dot(a: anytype, b: anytype) f32 {
    return @reduce(.Add, a * b);
}

fn slugDilate(pos: Vec4f, tex: Vec4f, jac: Vec4f, m0: Vec4f, m1: Vec4f, m3: Vec4f, dim: Vec2f) Vec4f {
    const pos_xy: Vec2f = .{ pos[0], pos[1] };
    const pos_zw: Vec2f = .{ pos[2], pos[3] };
    const m0_xy: Vec2f = .{ m0[0], m0[1] };
    const m1_xy: Vec2f = .{ m1[0], m1[1] };
    const m3_xy: Vec2f = .{ m3[0], m3[1] };
    const jac_xy: Vec2f = .{ jac[0], jac[1] };
    const jac_zw: Vec2f = .{ jac[2], jac[3] };

    const len = @sqrt(pos_zw[0] * pos_zw[0] + pos_zw[1] * pos_zw[1]);
    const n: Vec2f = pos_zw / @as(Vec2f, @splat(len));

    const s = dot(m3_xy, pos_xy) + m3[3];
    const t = dot(m3_xy, n);

    const u_ = (s * dot(m0_xy, n) - t * (dot(m0_xy, pos_xy) + m0[3])) * dim[0];
    const v_ = (s * dot(m1_xy, n) - t * (dot(m1_xy, pos_xy) + m1[3])) * dim[1];

    const s2 = s * s;
    const st = s * t;
    const uv = u_ * u_ + v_ * v_;
    const denom = @max(uv - st * st, 1.0e-12);
    const k = s2 * (st + @sqrt(uv)) / denom;
    const d: Vec2f = pos_zw * @as(Vec2f, @splat(k));

    const vpos = pos_xy + d;
    const vtex: Vec2f = .{
        tex[0] + dot(d, jac_xy),
        tex[1] + dot(d, jac_zw),
    };
    return .{ vpos[0], vpos[1], vtex[0], vtex[1] };
}

export fn main() callconv(.spirv_vertex) void {
    const m0 = u.*.mvp_row0;
    const m1 = u.*.mvp_row1;
    const m2 = u.*.mvp_row2;
    const m3 = u.*.mvp_row3;
    const vp = u.*.viewport;

    const dilated = slugDilate(
        in_pos.*,
        in_tex.*,
        in_jac.*,
        m0,
        m1,
        m3,
        .{ vp[2], vp[3] },
    );
    const px = dilated[0];
    const py = dilated[1];

    position = .{
        px * m0[0] + py * m0[1] + m0[3],
        px * m1[0] + py * m1[1] + m1[3],
        px * m2[0] + py * m2[1] + m2[3],
        px * m3[0] + py * m3[1] + m3[3],
    };

    out_texcoord.* = .{ dilated[2], dilated[3] };
    out_banding.* = in_bnd.*;
    out_color.* = in_col.*;
    out_world_pos.* = .{ px, py };
    out_clip_node.* = in_clip_node.*;

    const t = in_tex.*;
    const zb: u32 = @bitCast(t[2]);
    const wb: u32 = @bitCast(t[3]);
    out_glyph.* = .{
        @bitCast(zb & 0xFFFF),
        @bitCast(zb >> 16),
        @bitCast(wb & 0xFFFF),
        @bitCast(wb >> 16),
    };
}
