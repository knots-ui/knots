//! Zig port of the Slug analytic font rendering algorithm.
//! Reference: https://github.com/EricLengyel/Slug/tree/main

const common = @import("common.zig");

const Vec4f = common.Vec4f;
const Vec3f = common.Vec3f;
const Vec2f = common.Vec2f;
const Vec4i = common.Vec4i;
const Vec2i = common.Vec2i;
const storageBuffer = common.storageBuffer;
const uniformConstant = common.uniformConstant;
const input = common.input;
const output = common.output;

const LOG_BAND_TEXTURE_WIDTH: u5 = 12;

const curve_texture = uniformConstant(common.Image2D(f32), "curve_texture", .{ .descriptor = .{ .set = 1, .binding = 0 } });
const band_texture = uniformConstant(common.Image2D(u32), "band_texture", .{ .descriptor = .{ .set = 1, .binding = 1 } });
const clip_nodes = storageBuffer(common.ClipNodes, "clip_nodes", .{ .descriptor = .{ .set = 2, .binding = 0 } });

const in_color = input(Vec4f, "in_color", .{ .location = 0 });
const in_texcoord = input(Vec2f, "in_texcoord", .{ .location = 1 });
const in_banding = input(Vec4f, "in_banding", .{ .flat = 2 });
const in_glyph = input(Vec4i, "in_glyph", .{ .flat = 3 });
const in_world_pos = input(Vec2f, "in_world_pos", .{ .location = 4 });
const in_clip_node = input(f32, "in_clip_node", .{ .location = 5 });

const frag_color = output(Vec4f, "frag_color", .{ .location = 0 });

fn calcRootCode(y1: f32, y2: f32, y3: f32) u32 {
    const y1_sign = @as(u32, @bitCast(y1)) >> 31;
    const y2_sign = @as(u32, @bitCast(y2)) >> 30;
    const y3_sign = @as(u32, @bitCast(y3)) >> 29;

    var shift = (y2_sign & 2) | (y1_sign & ~@as(u32, 2));
    shift = (y3_sign & 4) | (shift & ~@as(u32, 4));

    return (@as(u32, 0x2E74) >> @as(u5, @intCast(shift))) & 0x0101;
}

fn solveHorizPoly(p12: Vec4f, p3: Vec2f) Vec2f {
    const a = Vec2f{ p12[0], p12[1] } - Vec2f{ p12[2], p12[3] } * @as(Vec2f, @splat(2.0)) + p3;
    const b = Vec2f{ p12[0], p12[1] } - Vec2f{ p12[2], p12[3] };
    const ra = 1.0 / a[1];
    const rb = 0.5 / b[1];

    const d = @sqrt(@max(b[1] * b[1] - a[1] * p12[1], 0.0));
    var t1 = (b[1] - d) * ra;
    var t2 = (b[1] + d) * ra;

    if (@abs(a[1]) < 1.0 / 65536.0) {
        const t = p12[1] * rb;
        t1 = t;
        t2 = t;
    }

    return .{
        (a[0] * t1 - b[0] * 2.0) * t1 + p12[0],
        (a[0] * t2 - b[0] * 2.0) * t2 + p12[0],
    };
}

fn solveVertPoly(p12: Vec4f, p3: Vec2f) Vec2f {
    const a = Vec2f{ p12[0], p12[1] } - Vec2f{ p12[2], p12[3] } * @as(Vec2f, @splat(2.0)) + p3;
    const b = Vec2f{ p12[0], p12[1] } - Vec2f{ p12[2], p12[3] };
    const ra = 1.0 / a[0];
    const rb = 0.5 / b[0];

    const d = @sqrt(@max(b[0] * b[0] - a[0] * p12[0], 0.0));
    var t1 = (b[0] - d) * ra;
    var t2 = (b[0] + d) * ra;

    if (@abs(a[0]) < 1.0 / 65536.0) {
        const t = p12[0] * rb;
        t1 = t;
        t2 = t;
    }

    return .{
        (a[1] * t1 - b[1] * 2.0) * t1 + p12[1],
        (a[1] * t2 - b[1] * 2.0) * t2 + p12[1],
    };
}

fn offsetTextureLoc(base: Vec2i, offset: i32) Vec2i {
    const mask = (@as(i32, 1) << LOG_BAND_TEXTURE_WIDTH) - 1;
    var x = base[0] + offset;
    const y_offset = asm (
        \\%int = OpTypeInt 32 1
        \\%uint = OpTypeInt 32 0
        \\%shift = OpConstant %uint 12
        \\%ret = OpShiftRightArithmetic %int %x %shift
        : [ret] "=r" (-> i32),
        : [x] "" (x),
    );
    const y = base[1] + y_offset;
    x &= mask;
    return .{ x, y };
}

fn intBits(value: u32) i32 {
    return @bitCast(value);
}

fn calcBandLoc(glyph_loc: Vec2i, offset: u32) Vec2i {
    return offsetTextureLoc(glyph_loc, intBits(offset));
}

fn calcCoverage(xcov: f32, ycov: f32, xwgt: f32, ywgt: f32) f32 {
    const combined = @abs(xcov * xwgt + ycov * ywgt) / @max(xwgt + ywgt, 1.0 / 65536.0);
    const alt = @min(@abs(xcov), @abs(ycov));
    return common.clamp(@max(combined, alt), 0.0, 1.0);
}

fn texelFetchBand(loc: Vec2i) common.Vec4u {
    return common.texelFetch2Du(band_texture, loc);
}

fn texelFetchCurve(loc: Vec2i) Vec4f {
    return common.texelFetch2Df(curve_texture, loc);
}

fn slugRender(render_coord: Vec2f, banding: Vec4f, glyph_data: Vec4i) f32 {
    const ems_per_pixel = common.fwidth2f(render_coord);
    const pixels_per_em = @as(Vec2f, @splat(1.0)) / ems_per_pixel;

    const band_max = Vec2i{ glyph_data[2], glyph_data[3] & 0x00FF };
    var band_index = Vec2i{
        @intFromFloat(render_coord[0] * banding[0] + banding[2]),
        @intFromFloat(render_coord[1] * banding[1] + banding[3]),
    };
    band_index = .{
        @min(@max(band_index[0], 0), band_max[0]),
        @min(@max(band_index[1], 0), band_max[1]),
    };
    const glyph_loc = Vec2i{ glyph_data[0], glyph_data[1] };

    var xcov: f32 = 0.0;
    var xwgt: f32 = 0.0;

    const hband = texelFetchBand(offsetTextureLoc(glyph_loc, band_index[1]));
    const hcount = intBits(hband[0]);
    const hloc = calcBandLoc(glyph_loc, hband[1]);

    var hi: i32 = 0;
    while (hi < hcount) : (hi += 1) {
        const curve_band = texelFetchBand(offsetTextureLoc(hloc, hi));
        const curve_loc = Vec2i{ intBits(curve_band[0]), intBits(curve_band[1]) };
        const p12 = texelFetchCurve(curve_loc) - Vec4f{ render_coord[0], render_coord[1], render_coord[0], render_coord[1] };
        const p3_texel = texelFetchCurve(offsetTextureLoc(curve_loc, 1));
        const p3 = Vec2f{ p3_texel[0] - render_coord[0], p3_texel[1] - render_coord[1] };

        if (@max(@max(p12[0], p12[2]), p3[0]) * pixels_per_em[0] < -0.5) break;

        const code = calcRootCode(p12[1], p12[3], p3[1]);
        if (code != 0) {
            const r = solveHorizPoly(p12, p3) * @as(Vec2f, @splat(pixels_per_em[0]));
            if ((code & 1) != 0) {
                xcov += common.clamp(r[0] + 0.5, 0.0, 1.0);
                xwgt = @max(xwgt, common.clamp(1.0 - @abs(r[0]) * 2.0, 0.0, 1.0));
            }
            if (code > 1) {
                xcov -= common.clamp(r[1] + 0.5, 0.0, 1.0);
                xwgt = @max(xwgt, common.clamp(1.0 - @abs(r[1]) * 2.0, 0.0, 1.0));
            }
        }
    }

    var ycov: f32 = 0.0;
    var ywgt: f32 = 0.0;

    const vband = texelFetchBand(offsetTextureLoc(glyph_loc, band_max[1] + 1 + band_index[0]));
    const vcount = intBits(vband[0]);
    const vloc = calcBandLoc(glyph_loc, vband[1]);

    var vi: i32 = 0;
    while (vi < vcount) : (vi += 1) {
        const curve_band = texelFetchBand(offsetTextureLoc(vloc, vi));
        const curve_loc = Vec2i{ intBits(curve_band[0]), intBits(curve_band[1]) };
        const p12 = texelFetchCurve(curve_loc) - Vec4f{ render_coord[0], render_coord[1], render_coord[0], render_coord[1] };
        const p3_texel = texelFetchCurve(offsetTextureLoc(curve_loc, 1));
        const p3 = Vec2f{ p3_texel[0] - render_coord[0], p3_texel[1] - render_coord[1] };

        if (@max(@max(p12[1], p12[3]), p3[1]) * pixels_per_em[1] < -0.5) break;

        const code = calcRootCode(p12[0], p12[2], p3[0]);
        if (code != 0) {
            const r = solveVertPoly(p12, p3) * @as(Vec2f, @splat(pixels_per_em[1]));
            if ((code & 1) != 0) {
                ycov -= common.clamp(r[0] + 0.5, 0.0, 1.0);
                ywgt = @max(ywgt, common.clamp(1.0 - @abs(r[0]) * 2.0, 0.0, 1.0));
            }
            if (code > 1) {
                ycov += common.clamp(r[1] + 0.5, 0.0, 1.0);
                ywgt = @max(ywgt, common.clamp(1.0 - @abs(r[1]) * 2.0, 0.0, 1.0));
            }
        }
    }

    return calcCoverage(xcov, ycov, xwgt, ywgt);
}

fn fragment(comptime encode_srgb: bool) void {
    const color = in_color.*;
    const coverage = slugRender(in_texcoord.*, in_banding.*, in_glyph.*);
    const alpha = color[3] * coverage * common.clipAlpha(clip_nodes, in_world_pos.*, in_clip_node.*);
    const col = Vec4f{ color[0] * alpha, color[1] * alpha, color[2] * alpha, alpha };
    if (comptime encode_srgb) {
        const srgb = common.linearToSrgb(Vec3f{ col[0], col[1], col[2] });
        frag_color.* = .{ srgb[0], srgb[1], srgb[2], col[3] };
    } else frag_color.* = col;
}

export fn fs_main() callconv(.{ .spirv_fragment = .{} }) void {
    fragment(false);
}

export fn fs_main_srgb_encode() callconv(.{ .spirv_fragment = .{} }) void {
    fragment(true);
}
