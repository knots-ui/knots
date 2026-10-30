const std = @import("std");
const unicode = @import("../unicode/root.zig");
const FontProgram = @import("../font/FontProgram.zig");
const Buffer = @import("Buffer.zig");
const Plan = @import("Plan.zig");
const props = @import("props.zig");
const apply = @import("apply.zig");
const gpos = @import("gpos.zig");
const normalize = @import("normalize.zig");

pub const ShapedGlyph = struct {
    glyph: u32,
    cluster: u32,
    x_advance: i32,
    x_offset: i32,
    y_offset: i32,
    flags: u8,
};

pub const unsafe_to_break: u8 = 0x1;
pub const unsafe_to_concat: u8 = 0x2;

pub fn shape(buffer: *Buffer, program: *const FontProgram, plan: *const Plan, text: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(ShapedGlyph)) !void {
    try shapeRanged(buffer, program, plan, text, plan.key_ranges, gpa, out);
}

/// Shapes with ranged features given in byte offsets into `text`.
pub fn shapeRanged(buffer: *Buffer, program: *const FontProgram, plan: *const Plan, text: []const u8, ranges: []const Plan.Feature, gpa: std.mem.Allocator, out: *std.ArrayList(ShapedGlyph)) !void {
    if (ranges.len == 0 and isFastPath(plan, text)) return shapeFast(program, text, gpa, out);
    try shapeFullRanged(buffer, program, plan, text, ranges, gpa, out);
}

pub fn isFastPath(plan: *const Plan, text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80 or !plan.ascii_fast[byte]) return false;
    }
    return true;
}

fn shapeFast(program: *const FontProgram, text: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(ShapedGlyph)) !void {
    try out.ensureUnusedCapacity(gpa, text.len);
    for (text, 0..) |byte, index| {
        const glyph = program.cmap.ascii[byte];
        out.appendAssumeCapacity(.{
            .glyph = glyph,
            .cluster = @intCast(index),
            .x_advance = program.advance(glyph),
            .x_offset = 0,
            .y_offset = 0,
            .flags = 0,
        });
    }
}

pub fn shapeFull(buffer: *Buffer, program: *const FontProgram, plan: *const Plan, text: []const u8, gpa: std.mem.Allocator, out: *std.ArrayList(ShapedGlyph)) !void {
    try shapeFullRanged(buffer, program, plan, text, plan.key_ranges, gpa, out);
}

fn shapeFullRanged(buffer: *Buffer, program: *const FontProgram, plan: *const Plan, text: []const u8, ranges: []const Plan.Feature, gpa: std.mem.Allocator, out: *std.ArrayList(ShapedGlyph)) !void {
    buffer.reset();
    try decode(buffer, text);
    buffer.startShaping();
    setUnicodeProps(buffer, plan.global_mask);
    formClusters(buffer);
    try substitutePre(buffer, program, plan, ranges);
    try position(buffer, program, plan);
    substitutePost(buffer, program);
    propagateFlags(buffer);
    try emit(buffer, gpa, out);
}

fn decode(buffer: *Buffer, text: []const u8) !void {
    try buffer.addText(text);
}

/// `props.unicodeProps` of every ASCII codepoint.
const ascii_props: [128]u16 = table: {
    @setEvalBranchQuota(100_000);
    var values: [128]u16 = undefined;
    for (&values, 0..) |*value, codepoint| value.* = props.unicodeProps(codepoint);
    break :table values;
};

fn setUnicodeProps(buffer: *Buffer, global_mask: u32) void {
    const s = buffer.slice();
    const ids = s.items(.id);
    const masks = s.items(.mask);
    const uprops = s.items(.unicode_props);
    const count = buffer.len;
    @memset(masks[0..count], global_mask);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const codepoint = ids[i];
        if (codepoint < 0x80) {
            uprops[i] = ascii_props[codepoint];
            continue;
        }
        uprops[i] = unicodePropsNoting(buffer, ids[i]);
        if (props.isUnicodeMark(uprops[i])) buffer.scratch.has_marks = true;
        switch (props.generalCategory(uprops[i])) {
            .lowercase_letter, .uppercase_letter, .titlecase_letter, .other_letter, .space_separator => continue,
            else => {},
        }
        if (props.generalCategory(uprops[i]) == .modifier_symbol and codepoint >= 0x1F3FB and codepoint <= 0x1F3FF) {
            setContinuation(buffer, &uprops[i]);
        } else if (i > 0 and unicode.isRegionalIndicator(codepoint)) {
            if (unicode.isRegionalIndicator(ids[i - 1]) and !props.isContinuation(uprops[i - 1])) setContinuation(buffer, &uprops[i]);
        } else if (props.isZwj(uprops[i])) {
            setContinuation(buffer, &uprops[i]);
            if (i + 1 < count and unicode.props(ids[i + 1]).extended_pictographic) {
                i += 1;
                uprops[i] = unicodePropsNoting(buffer, ids[i]);
                if (props.isUnicodeMark(uprops[i])) buffer.scratch.has_marks = true;
                setContinuation(buffer, &uprops[i]);
            }
        } else if ((codepoint >= 0xFF9E and codepoint <= 0xFF9F) or (codepoint >= 0xE0020 and codepoint <= 0xE007F)) {
            setContinuation(buffer, &uprops[i]);
        } else if (codepoint == 0x2044) {
            buffer.scratch.has_fraction_slash = true;
        }
    }
}

fn unicodePropsNoting(buffer: *Buffer, codepoint: u32) u16 {
    const result = props.unicodeProps(codepoint);
    if (result & props.ignorable != 0) buffer.scratch.has_default_ignorables = true;
    if (codepoint == 0x034F) buffer.scratch.has_cgj = true;
    if (result & props.continuation != 0) buffer.scratch.has_continuations = true;
    return result;
}

fn setContinuation(buffer: *Buffer, unicode_props: *u16) void {
    buffer.scratch.has_continuations = true;
    unicode_props.* |= props.continuation;
}

fn formClusters(buffer: *Buffer) void {
    if (!buffer.scratch.has_continuations) return;
    const uprops = buffer.field(.unicode_props);
    var start: u32 = 0;
    while (start < buffer.len) {
        var end = start + 1;
        while (end < buffer.len and props.isContinuation(uprops[end])) end += 1;
        buffer.mergeClusters(start, end);
        start = end;
    }
}

fn substitutePre(buffer: *Buffer, program: *const FontProgram, plan: *const Plan, ranges: []const Plan.Feature) !void {
    try normalize.normalize(buffer, program);
    setupMasks(buffer, plan, ranges);
    mapGlyphs(buffer, program);
    setGlyphProps(buffer, program, plan);
    try apply.applyTable(buffer, program, plan, .gsub);
}

fn mapGlyphs(buffer: *Buffer, program: *const FontProgram) void {
    const s = buffer.slice();
    for (s.items(.id), s.items(.class), s.items(.normalized)) |*id, *class, normalized| {
        id.* = normalized;
        class.* = program.partition.classOf(normalized);
    }
}

fn setupMasks(buffer: *Buffer, plan: *const Plan, ranges: []const Plan.Feature) void {
    setupFractionMasks(buffer, plan);
    for (ranges) |feature| {
        if (feature.isGlobal()) continue;
        const target = plan.mask(feature.tag);
        buffer.setMasks(feature.value << target.shift, target.mask, feature.start, feature.end);
    }
}

fn setupFractionMasks(buffer: *Buffer, plan: *const Plan) void {
    if (!buffer.scratch.has_fraction_slash or !plan.has_frac) return;
    const pre_mask = plan.numr_mask | plan.frac_mask;
    const post_mask = plan.frac_mask | plan.dnom_mask;
    const s = buffer.slice();
    const ids = s.items(.id);
    const uprops = s.items(.unicode_props);
    const masks = s.items(.mask);
    const count = buffer.len;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (ids[i] != 0x2044) continue;
        var start = i;
        var end = i + 1;
        while (start > 0 and props.generalCategory(uprops[start - 1]) == .decimal_number) start -= 1;
        while (end < count and props.generalCategory(uprops[end]) == .decimal_number) end += 1;
        if (start == i or end == i + 1) {
            if (start == i) buffer.unsafeToConcat(start, start + 1);
            if (end == i + 1) buffer.unsafeToConcat(end - 1, end);
            continue;
        }
        buffer.unsafeToBreak(start, end);
        for (start..i) |j| masks[j] |= pre_mask;
        masks[i] |= plan.frac_mask;
        for (i + 1..end) |j| masks[j] |= post_mask;
        i = end - 1;
    }
}

fn setGlyphProps(buffer: *Buffer, program: *const FontProgram, plan: *const Plan) void {
    const s = buffer.slice();
    for (s.items(.id), s.items(.glyph_props), s.items(.lig_props), s.items(.unicode_props)) |id, *glyph_props, *lig_props, uprops| {
        lig_props.* = 0;
        if (plan.fallback_glyph_classes) {
            glyph_props.* = synthesizedClass(uprops);
            continue;
        }
        glyph_props.* = program.gdef.props(id);
    }
}

fn synthesizedClass(unicode_props: u16) u16 {
    if (props.generalCategory(unicode_props) != .non_spacing_mark) return props.glyph_base;
    if (props.isDefaultIgnorable(unicode_props, 0)) return props.glyph_base;
    return props.glyph_mark;
}

fn position(buffer: *Buffer, program: *const FontProgram, plan: *const Plan) !void {
    buffer.clearPositions();
    const s = buffer.slice();
    for (s.items(.id), s.items(.x_advance)) |id, *advance| advance.* = program.advance(id);
    if (buffer.scratch.has_space_fallback) normalize.fallbackSpaces(buffer, program);

    if (plan.apply_gpos) try apply.applyTable(buffer, program, plan, .gpos);
    if (plan.apply_kern) gpos.applyKern(buffer, program, plan);
    const adjust_offsets = plan.adjust_mark_positioning_when_zeroing;
    if (plan.zero_marks) zeroMarkWidthsByGdef(buffer, adjust_offsets);
    zeroWidthDefaultIgnorables(buffer);
    gpos.propagateAttachmentOffsets(buffer);
}

fn zeroMarkWidthsByGdef(buffer: *Buffer, adjust_offsets: bool) void {
    const s = buffer.slice();
    for (s.items(.glyph_props), s.items(.x_advance), s.items(.x_offset)) |glyph_props, *advance, *offset| {
        if (!props.isMark(glyph_props)) continue;
        if (adjust_offsets) offset.* = saturatingSub(offset.*, advance.*);
        advance.* = 0;
    }
}

fn saturatingSub(a: i32, b: i32) i32 {
    return a -| b;
}

fn zeroWidthDefaultIgnorables(buffer: *Buffer) void {
    if (!buffer.scratch.has_default_ignorables) return;
    const s = buffer.slice();
    for (s.items(.unicode_props), s.items(.glyph_props), s.items(.x_advance), s.items(.x_offset)) |uprops, glyph_props, *advance, *offset| {
        if (!props.isDefaultIgnorable(uprops, glyph_props)) continue;
        advance.* = 0;
        offset.* = 0;
    }
}

fn substitutePost(buffer: *Buffer, program: *const FontProgram) void {
    hideDefaultIgnorables(buffer, program);
}

fn hideDefaultIgnorables(buffer: *Buffer, program: *const FontProgram) void {
    if (!buffer.scratch.has_default_ignorables) return;
    const space = program.cmap.glyph(' ');
    if (space == 0) {
        buffer.deleteGlyphsInplace(isIgnorableAt);
        return;
    }
    const s = buffer.slice();
    for (s.items(.id), s.items(.unicode_props), s.items(.glyph_props)) |*id, uprops, glyph_props| {
        if (props.isDefaultIgnorable(uprops, glyph_props)) id.* = space;
    }
}

fn isIgnorableAt(buffer: *Buffer, i: u32) bool {
    return props.isDefaultIgnorable(buffer.field(.unicode_props)[i], buffer.field(.glyph_props)[i]);
}

fn propagateFlags(buffer: *Buffer) void {
    const s = buffer.slice();
    const masks = s.items(.mask);
    const clusters = s.items(.cluster);
    var start: u32 = 0;
    while (start < buffer.len) {
        var end = start + 1;
        while (end < buffer.len and clusters[end] == clusters[start]) end += 1;
        var mask: u32 = 0;
        for (masks[start..end]) |glyph_mask| mask |= glyph_mask;
        mask &= Buffer.flag_defined;
        for (masks[start..end]) |*glyph_mask| glyph_mask.* = mask;
        start = end;
    }
}

fn emit(buffer: *Buffer, gpa: std.mem.Allocator, out: *std.ArrayList(ShapedGlyph)) !void {
    const s = buffer.slice();
    try out.ensureUnusedCapacity(gpa, buffer.len);
    for (0..buffer.len) |i| {
        out.appendAssumeCapacity(.{
            .glyph = s.items(.id)[i],
            .cluster = s.items(.cluster)[i],
            .x_advance = s.items(.x_advance)[i],
            .x_offset = s.items(.x_offset)[i],
            .y_offset = s.items(.y_offset)[i],
            .flags = @intCast(s.items(.mask)[i] & Buffer.flag_defined),
        });
    }
}
