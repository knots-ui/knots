//! Normalization against the font's cmap, ported from hb-ot-shape-normalize.cc
//! in its default mode (composed diacritics, short-circuiting simple clusters).

const std = @import("std");
const unicode = @import("../unicode/root.zig");
const FontProgram = @import("../font/FontProgram.zig");
const Buffer = @import("Buffer.zig");
const props = @import("props.zig");

pub const max_combining_marks = 32;

pub const SpaceType = enum(u8) {
    not_space = 0,
    em = 1,
    em_2 = 2,
    em_3 = 3,
    em_4 = 4,
    em_5 = 5,
    em_6 = 6,
    em_16 = 16,
    four_em_18 = 17,
    space = 18,
    figure = 19,
    punctuation = 20,
    narrow = 21,
};

pub fn spaceFallbackType(codepoint: u32) SpaceType {
    return switch (codepoint) {
        0x0020, 0x00A0 => .space,
        0x2000, 0x2002 => .em_2,
        0x2001, 0x2003, 0x3000 => .em,
        0x2004 => .em_3,
        0x2005 => .em_4,
        0x2006 => .em_6,
        0x2007 => .figure,
        0x2008 => .punctuation,
        0x2009 => .em_5,
        0x200A => .em_16,
        0x202F => .narrow,
        0x205F => .four_em_18,
        else => .not_space,
    };
}

const Normalizer = struct {
    buffer: *Buffer,
    program: *const FontProgram,

    fn glyph(self: *const Normalizer, codepoint: u32) ?u32 {
        const id = self.program.cmap.glyph(codepoint);
        if (id == 0) return null;
        return id;
    }

    fn setUnicodeProps(self: *Normalizer, position: u32) void {
        const codepoint = self.buffer.field(.id)[position];
        const value = props.unicodeProps(codepoint);
        if (value & props.ignorable != 0) self.buffer.scratch.has_default_ignorables = true;
        if (codepoint == 0x034F) self.buffer.scratch.has_cgj = true;
        if (value & props.continuation != 0) self.buffer.scratch.has_continuations = true;
        self.buffer.field(.unicode_props)[position] = value;
    }

    fn outputChar(self: *Normalizer, codepoint: u32, glyph_id: u32) !void {
        const buffer = self.buffer;
        buffer.field(.normalized)[buffer.cur()] = glyph_id;
        try buffer.outputGlyph(codepoint);
        self.setUnicodeProps(buffer.out_len - 1);
    }

    fn nextChar(self: *Normalizer, glyph_id: u32) void {
        const buffer = self.buffer;
        buffer.field(.normalized)[buffer.cur()] = glyph_id;
        buffer.nextGlyph();
    }

    fn decompose(self: *Normalizer, shortest: bool, ab: u32) !u32 {
        const pair = unicode.decompose(ab) orelse return 0;
        var b_glyph: u32 = 0;
        if (pair.second != 0) b_glyph = self.glyph(pair.second) orelse return 0;
        const a_glyph = self.glyph(pair.first);
        if (shortest and a_glyph != null) {
            try self.outputChar(pair.first, a_glyph.?);
            if (pair.second != 0) {
                try self.outputChar(pair.second, b_glyph);
                return 2;
            }
            return 1;
        }
        const nested = try self.decompose(shortest, pair.first);
        if (nested != 0) {
            if (pair.second != 0) {
                try self.outputChar(pair.second, b_glyph);
                return nested + 1;
            }
            return nested;
        }
        if (a_glyph) |found| {
            try self.outputChar(pair.first, found);
            if (pair.second != 0) {
                try self.outputChar(pair.second, b_glyph);
                return 2;
            }
            return 1;
        }
        return 0;
    }

    fn decomposeCurrentCharacter(self: *Normalizer, shortest: bool) !void {
        const buffer = self.buffer;
        const position = buffer.cur();
        const codepoint = buffer.field(.id)[position];
        if (shortest) {
            if (self.glyph(codepoint)) |found| return self.nextChar(found);
        }
        if (try self.decompose(shortest, codepoint) != 0) {
            buffer.skipGlyph();
            return;
        }
        if (!shortest) {
            if (self.glyph(codepoint)) |found| return self.nextChar(found);
        }
        const uprops = &buffer.field(.unicode_props)[buffer.cur()];
        if (props.generalCategory(uprops.*) == .space_separator) {
            const space_type = spaceFallbackType(codepoint);
            if (space_type != .not_space) {
                if (self.glyph(' ')) |space| {
                    uprops.* = (@as(u16, @backingInt(space_type)) << 8) | (uprops.* & 0xFF);
                    buffer.scratch.has_space_fallback = true;
                    return self.nextChar(space);
                }
            }
        }
        if (codepoint == 0x2011) {
            if (self.glyph(0x2010)) |found| return self.nextChar(found);
        }
        self.nextChar(0);
    }

    fn setGlyph(self: *Normalizer, position: u32) void {
        self.buffer.field(.normalized)[position] = self.program.cmap.glyph(self.buffer.field(.id)[position]);
    }

    fn handleVariationSelectorCluster(self: *Normalizer, end: u32) !void {
        const buffer = self.buffer;
        while (buffer.idx < end - 1 and buffer.successful) {
            const next = buffer.field(.id)[buffer.inPos(buffer.idx + 1)];
            if (unicode.isVariationSelector(next)) {
                const base = buffer.field(.id)[buffer.cur()];
                if (self.program.cmap.variationGlyph(base, next)) |variant| {
                    buffer.field(.normalized)[buffer.cur()] = variant;
                    try buffer.replaceGlyphs(2, &.{base});
                    while (buffer.idx < end and buffer.successful and unicode.isVariationSelector(buffer.field(.id)[buffer.cur()])) {
                        self.setGlyph(buffer.cur());
                        buffer.nextGlyph();
                    }
                    continue;
                }
                self.setGlyph(buffer.cur());
                buffer.nextGlyph();
                const selector = &buffer.field(.unicode_props)[buffer.cur()];
                props.setGeneralCategory(selector, .format);
                selector.* |= props.cf_vs;
                self.setGlyph(buffer.cur());
                buffer.nextGlyph();
                while (buffer.idx < end and buffer.successful and unicode.isVariationSelector(buffer.field(.id)[buffer.cur()])) {
                    self.setGlyph(buffer.cur());
                    buffer.nextGlyph();
                }
            } else {
                self.setGlyph(buffer.cur());
                buffer.nextGlyph();
            }
        }
        if (buffer.idx < end) {
            self.setGlyph(buffer.cur());
            buffer.nextGlyph();
        }
    }

    fn decomposeMultiCharCluster(self: *Normalizer, end: u32, short_circuit: bool) !void {
        const buffer = self.buffer;
        var i = buffer.idx;
        while (i < end and buffer.successful) : (i += 1) {
            if (unicode.isVariationSelector(buffer.field(.id)[buffer.inPos(i)])) {
                try self.handleVariationSelectorCluster(end);
                return;
            }
        }
        while (buffer.idx < end and buffer.successful) try self.decomposeCurrentCharacter(short_circuit);
    }
};

fn isMarkAt(buffer: *Buffer, i: u32) bool {
    return props.isUnicodeMark(buffer.field(.unicode_props)[buffer.inPos(i)]);
}

fn combiningClassAt(buffer: *Buffer, position: u32) u8 {
    return props.modifiedCombiningClass(buffer.field(.unicode_props)[position]);
}

pub fn normalize(buffer: *Buffer, program: *const FontProgram) !void {
    if (buffer.len == 0) return;
    if (!buffer.scratch.has_marks and mapAll(buffer, program)) return;
    var normalizer: Normalizer = .{ .buffer = buffer, .program = program };
    const might_short_circuit = true;
    const always_short_circuit = false;

    var all_simple = true;
    buffer.clearOutput();
    const count = buffer.len;
    buffer.idx = 0;
    while (true) {
        var end = buffer.idx + 1;
        while (end < count and !isMarkAt(buffer, end)) end += 1;
        if (end < count) end -= 1;
        if (might_short_circuit) {
            while (buffer.idx < end) {
                const position = buffer.cur();
                const found = program.cmap.glyph(buffer.field(.id)[position]);
                if (found == 0) break;
                buffer.field(.normalized)[position] = found;
                buffer.nextGlyph();
            }
        }
        while (buffer.idx < end and buffer.successful) try normalizer.decomposeCurrentCharacter(might_short_circuit);
        if (buffer.idx == count or !buffer.successful) break;
        all_simple = false;
        end = buffer.idx + 1;
        while (end < count and isMarkAt(buffer, end)) end += 1;
        try normalizer.decomposeMultiCharCluster(end, always_short_circuit);
        if (buffer.idx >= count or !buffer.successful) break;
    }
    buffer.sync();

    if (!all_simple) reorder(buffer);
    if (buffer.scratch.has_cgj) unhideCgj(buffer);
    if (!all_simple and buffer.successful) try recompose(buffer, program, &normalizer);
}

/// Without marks every cluster is one character: when the font maps all of them,
/// normalization is just the cmap lookup.
fn mapAll(buffer: *Buffer, program: *const FontProgram) bool {
    const s = buffer.slice();
    const ids = s.items(.id)[0..buffer.len];
    const normalized = s.items(.normalized)[0..buffer.len];
    for (ids, normalized) |codepoint, *glyph| {
        glyph.* = program.cmap.glyph(codepoint);
        if (glyph.* == 0) return false;
    }
    return true;
}

fn reorder(buffer: *Buffer) void {
    const count = buffer.len;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (combiningClassAt(buffer, i) == 0) continue;
        var end = i + 1;
        while (end < count and combiningClassAt(buffer, end) != 0) end += 1;
        if (end - i > max_combining_marks) {
            i = end;
            continue;
        }
        buffer.sort(i, end, {}, struct {
            fn lessThan(_: void, a: Buffer.Glyph, b: Buffer.Glyph) bool {
                return props.modifiedCombiningClass(a.unicode_props) < props.modifiedCombiningClass(b.unicode_props);
            }
        }.lessThan);
        i = end;
    }
}

fn unhideCgj(buffer: *Buffer) void {
    if (buffer.len < 3) return;
    const ids = buffer.field(.id);
    const uprops = buffer.field(.unicode_props);
    var i: u32 = 1;
    while (i + 1 < buffer.len) : (i += 1) {
        if (ids[i] != 0x034F) continue;
        const next = props.modifiedCombiningClass(uprops[i + 1]);
        if (next == 0 or props.modifiedCombiningClass(uprops[i - 1]) <= next) uprops[i] &= ~props.hidden;
    }
}

fn recompose(buffer: *Buffer, program: *const FontProgram, normalizer: *Normalizer) !void {
    buffer.clearOutput();
    const count = buffer.len;
    var starter: u32 = 0;
    buffer.nextGlyph();
    while (buffer.idx < count) {
        const current = buffer.cur();
        const uprops = buffer.field(.unicode_props);
        if (props.isUnicodeMark(uprops[current])) {
            const cc = props.modifiedCombiningClass(uprops[current]);
            const unblocked = starter == buffer.out_len - 1 or props.modifiedCombiningClass(uprops[buffer.out_len - 1]) < cc;
            if (unblocked) {
                if (composePair(buffer, program, starter, current)) |composed| {
                    buffer.nextGlyph();
                    buffer.mergeOutClusters(starter, buffer.out_len);
                    buffer.dropLastOutput();
                    buffer.field(.id)[starter] = composed.codepoint;
                    buffer.field(.normalized)[starter] = composed.glyph;
                    normalizer.setUnicodeProps(starter);
                    continue;
                }
            }
        }
        buffer.nextGlyph();
        if (props.modifiedCombiningClass(buffer.field(.unicode_props)[buffer.out_len - 1]) == 0) starter = buffer.out_len - 1;
    }
    buffer.sync();
}

const Composed = struct { codepoint: u32, glyph: u32 };

fn composePair(buffer: *Buffer, program: *const FontProgram, starter: u32, current: u32) ?Composed {
    const a = buffer.field(.id)[starter];
    const b = buffer.field(.id)[current];
    if (a == 0 or b == 0) return null;
    const composed = unicode.compose(a, b) orelse return null;
    const glyph = program.cmap.glyph(composed);
    if (glyph == 0) return null;
    return .{ .codepoint = composed, .glyph = glyph };
}

pub fn spaceType(unicode_props: u16) SpaceType {
    if (props.generalCategory(unicode_props) != .space_separator) return .not_space;
    const value: u8 = @intCast(unicode_props >> 8);
    inline for (comptime std.enums.values(SpaceType)) |kind| {
        if (value == @backingInt(kind)) return kind;
    }
    return .not_space;
}

/// `_hb_ot_shape_fallback_spaces`: advances for spaces the font lacks, mapped to U+0020.
pub fn fallbackSpaces(buffer: *Buffer, program: *const FontProgram) void {
    const s = buffer.slice();
    const upem: i64 = program.units_per_em;
    for (0..buffer.len) |i| {
        const uprops = s.items(.unicode_props)[i];
        if (props.generalCategory(uprops) != .space_separator) continue;
        if (s.items(.glyph_props)[i] & props.glyph_ligated != 0) continue;
        const advance = &s.items(.x_advance)[i];
        switch (spaceType(uprops)) {
            .not_space, .space => {},
            .em, .em_2, .em_3, .em_4, .em_5, .em_6, .em_16 => |kind| {
                const divisor: i64 = @backingInt(kind);
                advance.* = @intCast(@divTrunc(upem + @divTrunc(divisor, 2), divisor));
            },
            .four_em_18 => advance.* = @intCast(@divTrunc(upem * 4, 18)),
            .figure => for ("0123456789") |digit| {
                const glyph = program.cmap.glyph(digit);
                if (glyph == 0) continue;
                advance.* = program.advance(glyph);
                break;
            },
            .punctuation => {
                var glyph = program.cmap.glyph('.');
                if (glyph == 0) glyph = program.cmap.glyph(',');
                if (glyph != 0) advance.* = program.advance(glyph);
            },
            .narrow => advance.* = @divTrunc(advance.*, 2),
        }
    }
}
