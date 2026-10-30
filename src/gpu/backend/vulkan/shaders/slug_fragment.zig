//! Zig port of the Slug analytic font rendering algorithm.
//! Reference: https://github.com/EricLengyel/Slug/tree/main

const spirv = @import("spirv");
const ui = @import("ui.zig");

const Vec4f = spirv.Vec4f;
const Vec3f = spirv.Vec3f;
const Vec2f = spirv.Vec2f;
const Vec2i = spirv.Vec2i;
const storageBuffer = spirv.storageBuffer;
const input = spirv.input;
const output = spirv.output;

const glyph_words = storageBuffer(ui.GlyphWords, "glyph_words", .{ .descriptor = .{ .set = 1, .binding = 1 } });
const clip_nodes = storageBuffer(ui.ClipNodes, "clip_nodes", .{ .descriptor = .{ .set = 2, .binding = 0 } });

const in_color = input(Vec4f, "in_color", .{ .location = 0 });
const in_texcoord = input(Vec2f, "in_texcoord", .{ .location = 1 });
const in_banding = input(Vec4f, "in_banding", .{ .flat = 2 });
const in_glyph = input(spirv.Vec4u, "in_glyph", .{ .flat = 3 });
const in_quant = input(Vec4f, "in_quant", .{ .flat = 4 });
const in_world_pos = input(Vec2f, "in_world_pos", .{ .location = 5 });
const in_clip_node = input(f32, "in_clip_node", .{ .location = 6 });

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

fn word(index: u32) u32 {
    return glyph_words.*.words[index];
}

fn glyphPoint(index: u32, quant: Vec4f) Vec2f {
    const value = word(index);
    const q = Vec2f{ @floatFromInt(value & 0xFFFF), @floatFromInt(value >> 16) };
    return Vec2f{ quant[0], quant[1] } + q * Vec2f{ quant[2], quant[3] };
}

fn bandCurve(list: u32, i: u32) u32 {
    const shift: u5 = @intCast((i & 1) * 16);
    return (word(list + (i >> 1)) >> shift) & 0xFFFF;
}

fn intBits(value: u32) i32 {
    return @bitCast(value);
}

fn calcCoverage(xcov: f32, ycov: f32, xwgt: f32, ywgt: f32) f32 {
    const combined = @abs(xcov * xwgt + ycov * ywgt) / @max(xwgt + ywgt, 1.0 / 65536.0);
    const alt = @min(@abs(xcov), @abs(ycov));
    return spirv.clamp(@max(combined, alt), 0.0, 1.0);
}

fn slugRender(render_coord: Vec2f, banding: Vec4f, glyph_data: spirv.Vec4u, quant: Vec4f) f32 {
    const ems_per_pixel = spirv.fwidth2f(render_coord);
    const pixels_per_em = @as(Vec2f, @splat(1.0)) / ems_per_pixel;

    const band_max = Vec2i{ intBits(glyph_data[2]), intBits(glyph_data[3]) };
    var band_index = Vec2i{
        @intFromFloat(render_coord[0] * banding[0] + banding[2]),
        @intFromFloat(render_coord[1] * banding[1] + banding[3]),
    };
    band_index = .{
        @min(@max(band_index[0], 0), band_max[0]),
        @min(@max(band_index[1], 0), band_max[1]),
    };
    const blob = glyph_data[0];
    const points = blob + glyph_data[1];
    const coord = Vec4f{ render_coord[0], render_coord[1], render_coord[0], render_coord[1] };

    var xcov: f32 = 0.0;
    var xwgt: f32 = 0.0;

    const hband = word(blob + @as(u32, @bitCast(band_index[1])));
    const hcount = hband & 0xFFFF;
    const hlist = blob + (hband >> 16);

    var hi: u32 = 0;
    while (hi < hcount) : (hi += 1) {
        const curve = points + bandCurve(hlist, hi);
        const p1 = glyphPoint(curve, quant);
        const p2 = glyphPoint(curve + 1, quant);
        const p12 = Vec4f{ p1[0], p1[1], p2[0], p2[1] } - coord;
        const p3 = glyphPoint(curve + 2, quant) - render_coord;

        if (@max(@max(p12[0], p12[2]), p3[0]) * pixels_per_em[0] < -0.5) break;

        const code = calcRootCode(p12[1], p12[3], p3[1]);
        if (code != 0) {
            const r = solveHorizPoly(p12, p3) * @as(Vec2f, @splat(pixels_per_em[0]));
            if ((code & 1) != 0) {
                xcov += spirv.clamp(r[0] + 0.5, 0.0, 1.0);
                xwgt = @max(xwgt, spirv.clamp(1.0 - @abs(r[0]) * 2.0, 0.0, 1.0));
            }
            if (code > 1) {
                xcov -= spirv.clamp(r[1] + 0.5, 0.0, 1.0);
                xwgt = @max(xwgt, spirv.clamp(1.0 - @abs(r[1]) * 2.0, 0.0, 1.0));
            }
        }
    }

    var ycov: f32 = 0.0;
    var ywgt: f32 = 0.0;

    const vband = word(blob + @as(u32, @bitCast(band_max[1] + 1 + band_index[0])));
    const vcount = vband & 0xFFFF;
    const vlist = blob + (vband >> 16);

    var vi: u32 = 0;
    while (vi < vcount) : (vi += 1) {
        const curve = points + bandCurve(vlist, vi);
        const p1 = glyphPoint(curve, quant);
        const p2 = glyphPoint(curve + 1, quant);
        const p12 = Vec4f{ p1[0], p1[1], p2[0], p2[1] } - coord;
        const p3 = glyphPoint(curve + 2, quant) - render_coord;

        if (@max(@max(p12[1], p12[3]), p3[1]) * pixels_per_em[1] < -0.5) break;

        const code = calcRootCode(p12[0], p12[2], p3[0]);
        if (code != 0) {
            const r = solveVertPoly(p12, p3) * @as(Vec2f, @splat(pixels_per_em[1]));
            if ((code & 1) != 0) {
                ycov -= spirv.clamp(r[0] + 0.5, 0.0, 1.0);
                ywgt = @max(ywgt, spirv.clamp(1.0 - @abs(r[0]) * 2.0, 0.0, 1.0));
            }
            if (code > 1) {
                ycov += spirv.clamp(r[1] + 0.5, 0.0, 1.0);
                ywgt = @max(ywgt, spirv.clamp(1.0 - @abs(r[1]) * 2.0, 0.0, 1.0));
            }
        }
    }

    return calcCoverage(xcov, ycov, xwgt, ywgt);
}

fn fragment(comptime encode_srgb: bool) void {
    const color = in_color.*;
    const coverage = slugRender(in_texcoord.*, in_banding.*, in_glyph.*, in_quant.*);
    const alpha = color[3] * coverage * ui.clipAlpha(clip_nodes, in_world_pos.*, in_clip_node.*);
    const col = Vec4f{ color[0] * alpha, color[1] * alpha, color[2] * alpha, alpha };
    if (comptime encode_srgb) {
        const srgb = ui.linearToSrgb(Vec3f{ col[0], col[1], col[2] });
        frag_color.* = .{ srgb[0], srgb[1], srgb[2], col[3] };
    } else frag_color.* = col;
}

export fn fs_main() callconv(.{ .spirv_fragment = .{} }) void {
    fragment(false);
}

export fn fs_main_srgb_encode() callconv(.{ .spirv_fragment = .{} }) void {
    fragment(true);
}
