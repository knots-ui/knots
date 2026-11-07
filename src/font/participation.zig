//! Whether the space glyph takes part in shaping: it is matched by a reachable
//! lookup's input or context, forms a kerning pair, or a lookup matching several
//! glyphs could skip over it. When it doesn't, text can be shaped word by word.

const std = @import("std");
const FontProgram = @import("FontProgram.zig");
const Layout = @import("Layout.zig");

pub fn spaceParticipates(program: *const FontProgram, lookups: anytype, apply_kern: bool) bool {
    if (apply_kern and program.kern.hasPairWith(program.space_glyph)) {
        return true;
    }
    var visited: [2]std.StaticBitSet(1 << 16) = .{ .empty, .empty };
    for (lookups, 0..) |list, table_index| {
        for (list) |lookup| {
            if (lookupParticipates(program, table_index, lookup.index, &visited, 0)) {
                return true;
            }
        }
    }
    return false;
}

const nesting_max = 64;

fn layoutOf(program: *const FontProgram, table_index: usize) *const Layout {
    return switch (table_index) {
        0 => &program.gsub,
        else => &program.gpos,
    };
}

/// Lookups that match more than one glyph, and so could match across a glyph they skip.
pub fn spansGlyphs(kind: Layout.Kind) bool {
    return switch (kind) {
        .none, .single_subst, .multiple_subst, .alternate_subst, .single_pos => false,
        else => true,
    };
}

fn lookupParticipates(program: *const FontProgram, table_index: usize, index: u16, visited: *[2]std.StaticBitSet(1 << 16), depth: u32) bool {
    if (depth > nesting_max or visited[table_index].isSet(index)) {
        return false;
    }
    visited[table_index].set(index);
    const layout = layoutOf(program, table_index);
    if (index >= layout.lookups.len) {
        return false;
    }
    const lookup = &layout.lookups[index];
    if (spansGlyphs(lookup.kind) and program.skipsGlyph(lookup.props(), program.space_glyph)) {
        return true;
    }
    for (lookup.subtables) |*subtable| {
        if (subtableParticipates(program, subtable)) {
            return true;
        }
        switch (subtable.kind) {
            .context, .chain_context => for (subtable.data.records) |record| {
                if (lookupParticipates(program, table_index, record.lookup, visited, depth + 1)) {
                    return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn subtableParticipates(program: *const FontProgram, subtable: *const Layout.Subtable) bool {
    const partition = &program.partition;
    const space = program.space_glyph;
    const space_class = partition.classOf(space);
    const data = &subtable.data;
    if (partition.contains(subtable.coverage_id, space_class)) {
        return true;
    }
    switch (subtable.kind) {
        .reverse_chain_subst, .mark_base_pos, .mark_ligature_pos, .mark_mark_pos => {
            for (subtable.predicates) |id| {
                if (partition.contains(id, space_class)) {
                    return true;
                }
            }
        },
        .ligature_subst => for (data.ligatures) |ligature| {
            if (ligature.component_count == Layout.Ligature.absent) {
                continue;
            }
            if (std.mem.findScalar(u16, data.components(ligature), @intCast(space)) != null) {
                return true;
            }
        },
        .pair_pos => switch (subtable.format) {
            1 => for (data.pairs) |pair| {
                if (pair.second == space) {
                    return true;
                }
            },
            else => {
                const second = partition.value(subtable.predicates[1], space_class);
                if (second >= data.class2_count) {
                    return false;
                }
                for (0..data.class1_count) |first| {
                    const cell = data.matrix[first * data.class2_count + second];
                    if (cell[0].nonzero or cell[0].device or cell[1].nonzero or cell[1].device) {
                        return true;
                    }
                }
            },
        },
        .context, .chain_context => switch (subtable.format) {
            1 => for (data.rules) |rule| {
                for ([_][]const u16{ data.backtrack(rule), data.input(rule), data.lookahead(rule) }) |sequence| {
                    if (std.mem.findScalar(u16, sequence, @intCast(space)) != null) {
                        return true;
                    }
                }
            },
            2 => return classRulesReference(program, subtable, space_class),
            else => for (subtable.predicates) |id| {
                if (partition.contains(id, space_class)) {
                    return true;
                }
            },
        },
        else => {},
    }
    return false;
}

fn classRulesReference(program: *const FontProgram, subtable: *const Layout.Subtable, space_class: u16) bool {
    const partition = &program.partition;
    const ids = subtable.predicates;
    const data = &subtable.data;
    const chained = subtable.kind == .chain_context;
    var values: [3]u16 = .{ 0, partition.value(ids[0], space_class), 0 };
    if (chained) {
        values = .{ partition.value(ids[0], space_class), partition.value(ids[1], space_class), partition.value(ids[2], space_class) };
    }
    for (0..data.sets.len -| 1) |first_class| {
        for (data.ruleRange(@intCast(first_class))) |rule| {
            if (std.meta.eql(rule, Layout.Rule.empty)) {
                continue;
            }
            if (first_class == values[1]) {
                return true;
            }
            for ([_][]const u16{ data.backtrack(rule), data.input(rule), data.lookahead(rule) }, 0..) |sequence, role| {
                if (!chained and role != 1) {
                    continue;
                }
                if (std.mem.findScalar(u16, sequence, values[role]) != null) {
                    return true;
                }
            }
        }
    }
    return false;
}
