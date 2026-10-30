//! Line break opportunities by UAX #14, following the numbered rules of the UCD's
//! LineBreakTest. Rules up to LB10 fold combining marks into units, and every later
//! rule compares units.

const std = @import("std");
const unicode = @import("root.zig");

const LineBreak = unicode.LineBreak;

pub const Break = enum(u2) { none, allowed, mandatory };

/// A base character with the combining marks and joiners that follow it (LB9).
const Unit = struct {
    start: u32,
    class: LineBreak,
    east_asian: bool,
    initial_quote: bool,
    final_quote: bool,
    unassigned_pictographic: bool,
    dotted_circle: bool,
    ends_with_zwj: bool,
};

pub const Scratch = struct {
    units: std.ArrayList(Unit) = .empty,

    pub fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        self.units.deinit(gpa);
    }
};

/// LB1: classes resolved for the rules.
fn resolve(class: LineBreak, category: unicode.GeneralCategory) LineBreak {
    return switch (class) {
        .ai, .sg, .xx => .al,
        .sa => switch (category) {
            .non_spacing_mark, .spacing_mark => .cm,
            else => .al,
        },
        .cj => .ns,
        else => class,
    };
}

fn absorbs(class: LineBreak) bool {
    return switch (class) {
        .bk, .cr, .lf, .nl, .sp, .zw => false,
        else => true,
    };
}

/// Writes the opportunity before each byte of `text` to `out`, which has `text.len` entries.
/// Bytes inside a codepoint, and the start of the text, get `.none`.
pub fn opportunities(gpa: std.mem.Allocator, scratch: *Scratch, text: []const u8, out: []Break) !void {
    std.debug.assert(out.len == text.len);
    @memset(out, .none);
    const units = &scratch.units;
    units.clearRetainingCapacity();
    var index: usize = 0;
    while (index < text.len) {
        const decoded = unicode.decodeUtf8(text, index);
        const props = unicode.props(decoded.codepoint);
        const class = resolve(props.line_break, props.general_category);
        defer index += decoded.len;
        if (class == .cm or class == .zwj) {
            if (units.items.len > 0 and absorbs(units.items[units.items.len - 1].class)) {
                units.items[units.items.len - 1].ends_with_zwj = class == .zwj;
                continue;
            }
        }
        var effective = class;
        if (class == .cm or class == .zwj) {
            effective = .al;
        }
        try units.append(gpa, .{
            .start = @intCast(index),
            .class = effective,
            .east_asian = props.east_asian_wide,
            .initial_quote = props.general_category == .initial_punctuation,
            .final_quote = props.general_category == .final_punctuation,
            .unassigned_pictographic = props.extended_pictographic and props.general_category == .unassigned,
            .dotted_circle = decoded.codepoint == 0x25CC,
            .ends_with_zwj = class == .zwj,
        });
    }
    const list = units.items;
    if (list.len < 2) {
        return;
    }
    for (1..list.len) |k| {
        out[list[k].start] = decide(list, k);
    }
}

fn classAt(units: []const Unit, k: isize) ?LineBreak {
    if (k < 0 or k >= units.len) {
        return null;
    }
    return units[@intCast(k)].class;
}

fn isAny(class: ?LineBreak, comptime set: []const LineBreak) bool {
    const value = class orelse return false;
    inline for (set) |member| {
        if (value == member) {
            return true;
        }
    }
    return false;
}

/// Index of the last unit at or before `k` that is not a space, or -1.
fn skipSpacesBack(units: []const Unit, k: isize) isize {
    var j = k;
    while (j >= 0 and units[@intCast(j)].class == .sp) {
        j -= 1;
    }
    return j;
}

fn isAksara(unit: Unit, allow_as: bool) bool {
    return unit.class == .ak or unit.dotted_circle or (allow_as and unit.class == .as);
}

/// The break between unit `k - 1` and unit `k`.
fn decide(units: []const Unit, k: usize) Break {
    const a = units[k - 1];
    const b = units[k];
    const ki: isize = @intCast(k);
    const after = classAt(units, ki + 1);

    // LB4 to LB8a.
    if (a.class == .bk) {
        return .mandatory;
    }
    if (a.class == .cr and b.class == .lf) {
        return .none;
    }
    if (isAny(a.class, &.{ .cr, .lf, .nl })) {
        return .mandatory;
    }
    if (isAny(b.class, &.{ .bk, .cr, .lf, .nl, .sp, .zw })) {
        return .none;
    }
    if (classAt(units, skipSpacesBack(units, ki - 1)) == .zw) {
        return .allowed;
    }
    if (a.ends_with_zwj) {
        return .none;
    }

    // LB11 to LB13.
    if (b.class == .wj or a.class == .wj) {
        return .none;
    }
    if (a.class == .gl) {
        return .none;
    }
    if (b.class == .gl and !isAny(a.class, &.{ .sp, .hy, .hh })) {
        return .none;
    }
    if (isAny(b.class, &.{ .ex, .cl, .cp, .sy })) {
        return .none;
    }

    // LB14 to LB17.
    const before_spaces = skipSpacesBack(units, ki - 1);
    const before_spaces_class = classAt(units, before_spaces);
    if (before_spaces_class == .op) {
        return .none;
    }
    if (before_spaces_class == .qu and units[@intCast(before_spaces)].initial_quote) {
        const preceding = classAt(units, before_spaces - 1);
        if (preceding == null or isAny(preceding, &.{ .bk, .cr, .lf, .nl, .op, .qu, .gl, .sp, .zw })) {
            return .none;
        }
    }
    if (b.class == .qu and b.final_quote) {
        if (after == null or isAny(after, &.{ .sp, .gl, .wj, .cl, .qu, .cp, .ex, .is, .sy, .bk, .cr, .lf, .nl, .zw })) {
            return .none;
        }
    }
    if (a.class == .sp and b.class == .is and after == .nu) {
        return .allowed;
    }
    if (b.class == .is) {
        return .none;
    }
    if (b.class == .ns and isAny(before_spaces_class, &.{ .cl, .cp })) {
        return .none;
    }
    if (b.class == .b2 and before_spaces_class == .b2) {
        return .none;
    }

    // LB18 to LB19a.
    if (a.class == .sp) {
        return .allowed;
    }
    if (b.class == .qu and !b.initial_quote) {
        return .none;
    }
    if (a.class == .qu and !a.final_quote) {
        return .none;
    }
    if (b.class == .qu and !a.east_asian) {
        return .none;
    }
    if (b.class == .qu and (k + 1 == units.len or !units[k + 1].east_asian)) {
        return .none;
    }
    if (a.class == .qu and !b.east_asian) {
        return .none;
    }
    if (a.class == .qu and (k < 2 or !units[k - 2].east_asian)) {
        return .none;
    }

    // LB20 to LB22.
    if (b.class == .cb or a.class == .cb) {
        return .allowed;
    }
    if (isAny(a.class, &.{ .hy, .hh }) and isAny(b.class, &.{ .al, .hl })) {
        const preceding = classAt(units, ki - 2);
        if (preceding == null or isAny(preceding, &.{ .bk, .cr, .lf, .nl, .sp, .zw, .cb, .gl })) {
            return .none;
        }
    }
    if (isAny(b.class, &.{ .ba, .hh, .hy, .ns })) {
        return .none;
    }
    if (a.class == .bb) {
        return .none;
    }
    if (isAny(a.class, &.{ .hy, .hh }) and classAt(units, ki - 2) == .hl and b.class != .hl) {
        return .none;
    }
    if (a.class == .sy and b.class == .hl) {
        return .none;
    }
    if (b.class == .in) {
        return .none;
    }

    // LB23 to LB24.
    if (isAny(a.class, &.{ .al, .hl }) and b.class == .nu) {
        return .none;
    }
    if (a.class == .nu and isAny(b.class, &.{ .al, .hl })) {
        return .none;
    }
    if (a.class == .pr and isAny(b.class, &.{ .id, .eb, .em })) {
        return .none;
    }
    if (isAny(a.class, &.{ .id, .eb, .em }) and b.class == .po) {
        return .none;
    }
    if (isAny(a.class, &.{ .pr, .po }) and isAny(b.class, &.{ .al, .hl })) {
        return .none;
    }
    if (isAny(a.class, &.{ .al, .hl }) and isAny(b.class, &.{ .pr, .po })) {
        return .none;
    }

    // LB25: numbers.
    if (isAny(b.class, &.{ .po, .pr }) and numberBefore(units, ki - 1, true)) {
        return .none;
    }
    if (isAny(a.class, &.{ .po, .pr })) {
        if (b.class == .op and after == .nu) {
            return .none;
        }
        if (b.class == .op and after == .is and classAt(units, ki + 2) == .nu) {
            return .none;
        }
        if (b.class == .nu) {
            return .none;
        }
    }
    if (isAny(a.class, &.{ .hy, .is }) and b.class == .nu) {
        return .none;
    }
    if (b.class == .nu and numberBefore(units, ki - 1, false)) {
        return .none;
    }

    // LB26 and LB27: Korean syllables.
    if (a.class == .jl and isAny(b.class, &.{ .jl, .jv, .h2, .h3 })) {
        return .none;
    }
    if (isAny(a.class, &.{ .jv, .h2 }) and isAny(b.class, &.{ .jv, .jt })) {
        return .none;
    }
    if (isAny(a.class, &.{ .jt, .h3 }) and b.class == .jt) {
        return .none;
    }
    if (isAny(a.class, &.{ .jl, .jv, .jt, .h2, .h3 }) and b.class == .po) {
        return .none;
    }
    if (a.class == .pr and isAny(b.class, &.{ .jl, .jv, .jt, .h2, .h3 })) {
        return .none;
    }

    // LB28 to LB30b.
    if (isAny(a.class, &.{ .al, .hl }) and isAny(b.class, &.{ .al, .hl })) {
        return .none;
    }
    if (a.class == .ap and isAksara(b, true)) {
        return .none;
    }
    if (isAksara(a, true) and isAny(b.class, &.{ .vf, .vi })) {
        return .none;
    }
    if (a.class == .vi and k >= 2 and isAksara(units[k - 2], true) and isAksara(b, false)) {
        return .none;
    }
    if (isAksara(a, true) and isAksara(b, true) and after == .vf) {
        return .none;
    }
    if (a.class == .is and isAny(b.class, &.{ .al, .hl })) {
        return .none;
    }
    if (isAny(a.class, &.{ .al, .hl, .nu }) and b.class == .op and !b.east_asian) {
        return .none;
    }
    if (a.class == .cp and !a.east_asian and isAny(b.class, &.{ .al, .hl, .nu })) {
        return .none;
    }
    if (a.class == .ri and b.class == .ri) {
        var count: usize = 0;
        var j = ki - 1;
        while (j >= 0 and units[@intCast(j)].class == .ri) : (j -= 1) {
            count += 1;
        }
        if (count % 2 == 1) {
            return .none;
        }
        return .allowed;
    }
    if (b.class == .em and (a.class == .eb or a.unassigned_pictographic)) {
        return .none;
    }
    return .allowed;
}

/// LB25: whether `NU (SY | IS)*`, optionally followed by one CL or CP, ends at unit `k`.
fn numberBefore(units: []const Unit, k: isize, allow_close: bool) bool {
    var j = k;
    if (allow_close and isAny(classAt(units, j), &.{ .cl, .cp })) {
        j -= 1;
    }
    while (isAny(classAt(units, j), &.{ .sy, .is })) {
        j -= 1;
    }
    return classAt(units, j) == .nu;
}

test "breaks after spaces and keeps words whole" {
    const text = "hello world, (a-b)";
    var out: [text.len]Break = undefined;
    var scratch: Scratch = .{};
    defer scratch.deinit(std.testing.allocator);
    try opportunities(std.testing.allocator, &scratch, text, &out);
    try std.testing.expectEqual(Break.allowed, out[6]);
    try std.testing.expectEqual(Break.none, out[5]);
    try std.testing.expectEqual(Break.none, out[2]);
    try std.testing.expectEqual(Break.allowed, out[13]);
}
