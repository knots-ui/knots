//! Whether the space glyph takes part in shaping: it is matched by a reachable
//! lookup's input or context, or forms a kerning pair. When it doesn't, text
//! can be shaped word by word.

const std = @import("std");
const FontProgram = @import("FontProgram.zig");
const Layout = @import("Layout.zig");
const Reader = @import("Reader.zig");

pub fn spaceParticipates(program: *const FontProgram, lookups: anytype, apply_kern: bool) bool {
    if (apply_kern and program.kern.hasPairWith(program.space_glyph)) return true;
    var visited: [2]std.StaticBitSet(1 << 16) = .{ .empty, .empty };
    for (lookups, 0..) |list, table_index| {
        for (list) |lookup| {
            if (lookupParticipates(program, table_index, lookup.index, &visited, 0)) return true;
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

fn lookupParticipates(program: *const FontProgram, table_index: usize, index: u16, visited: *[2]std.StaticBitSet(1 << 16), depth: u32) bool {
    if (depth > nesting_max or visited[table_index].isSet(index)) return false;
    visited[table_index].set(index);
    const layout = layoutOf(program, table_index);
    if (index >= layout.lookups.len) return false;
    for (layout.lookups[index].subtables) |subtable| {
        if (subtableParticipates(program, subtable)) return true;
        var records = NestedLookups.init(subtable);
        while (records.next()) |nested| {
            if (lookupParticipates(program, table_index, nested, visited, depth + 1)) return true;
        }
    }
    return false;
}

fn subtableParticipates(program: *const FontProgram, subtable: Layout.Subtable) bool {
    const partition = &program.partition;
    const space = program.space_glyph;
    const space_class = partition.classOf(space);
    if (partition.contains(subtable.coverage_id, space_class)) return true;
    switch (subtable.kind) {
        .reverse_chain_subst, .mark_base_pos, .mark_ligature_pos, .mark_mark_pos => {
            for (subtable.predicates) |id| {
                if (partition.contains(id, space_class)) return true;
            }
        },
        .ligature_subst => return ligatureNames(subtable.reader, space),
        .pair_pos => switch (subtable.format) {
            1 => return pairSetNames(subtable.reader, space),
            else => return pairClassParticipates(program, subtable, space_class),
        },
        .context, .chain_context => switch (subtable.format) {
            1 => return ruleNames(subtable, space),
            2 => return classRulesReference(program, subtable, space_class),
            else => for (subtable.predicates) |id| {
                if (partition.contains(id, space_class)) return true;
            },
        },
        else => {},
    }
    return false;
}

fn ligatureNames(reader: Reader, glyph: u32) bool {
    const set_count = reader.u16At(4) catch return false;
    for (0..set_count) |set_index| {
        const set = offsetTarget(reader, 6 + set_index * 2) orelse continue;
        const count = set.u16At(0) catch continue;
        for (0..count) |ligature_index| {
            const ligature = offsetTarget(set, 2 + ligature_index * 2) orelse continue;
            const components = ligature.u16At(2) catch continue;
            for (1..@max(components, 1)) |component| {
                if ((ligature.u16At(4 + (component - 1) * 2) catch continue) == glyph) return true;
            }
        }
    }
    return false;
}

fn pairSetNames(reader: Reader, glyph: u32) bool {
    const record_size = 2 + Layout.valueRecordSize(reader.u16At(4) catch return false) + Layout.valueRecordSize(reader.u16At(6) catch return false);
    const set_count = reader.u16At(8) catch return false;
    for (0..set_count) |set_index| {
        const set = offsetTarget(reader, 10 + set_index * 2) orelse continue;
        const count = set.u16At(0) catch continue;
        for (0..count) |pair| {
            if ((set.u16At(2 + pair * record_size) catch continue) == glyph) return true;
        }
    }
    return false;
}

fn pairClassParticipates(program: *const FontProgram, subtable: Layout.Subtable, space_class: u16) bool {
    const reader = subtable.reader;
    const format1 = reader.u16At(4) catch return false;
    const format2 = reader.u16At(6) catch return false;
    const size1 = Layout.valueRecordSize(format1);
    const record_size = size1 + Layout.valueRecordSize(format2);
    const class1_count = reader.u16At(12) catch return false;
    const class2_count = reader.u16At(14) catch return false;
    const second = program.partition.value(subtable.predicates[1], space_class);
    if (second >= class2_count) return false;
    for (0..class1_count) |first| {
        const record = 16 + (first * class2_count + second) * record_size;
        for (0..record_size / 2) |word| {
            if ((reader.u16At(record + word * 2) catch 0) != 0) return true;
        }
    }
    return false;
}

fn ruleNames(subtable: Layout.Subtable, glyph: u32) bool {
    var rules = Rules.init(subtable);
    while (rules.next()) |rule| {
        for (rule.sequences) |sequence| {
            for (0..sequence.count) |index| {
                if ((sequence.reader.u16At(sequence.position + index * 2) catch continue) == glyph) return true;
            }
        }
    }
    return false;
}

fn classRulesReference(program: *const FontProgram, subtable: Layout.Subtable, space_class: u16) bool {
    const partition = &program.partition;
    const ids = subtable.predicates;
    const values: [3]u16 = switch (subtable.kind) {
        .context => .{ 0, partition.value(ids[0], space_class), 0 },
        else => .{ partition.value(ids[0], space_class), partition.value(ids[1], space_class), partition.value(ids[2], space_class) },
    };
    var rules = Rules.init(subtable);
    while (rules.next()) |rule| {
        if (rule.first_class == values[1]) return true;
        for (rule.sequences, 0..) |sequence, role| {
            if (subtable.kind == .context and role != 1) continue;
            for (0..sequence.count) |index| {
                if ((sequence.reader.u16At(sequence.position + index * 2) catch continue) == values[role]) return true;
            }
        }
    }
    return false;
}

fn offsetTarget(reader: Reader, position: usize) ?Reader {
    const offset = reader.u16At(position) catch return null;
    if (offset == 0) return null;
    return reader.sub(offset) catch null;
}

pub const Sequence = struct { reader: Reader, position: usize, count: usize };

pub const Rule = struct {
    first_class: u32,
    sequences: [3]Sequence,
    lookups: Sequence,
};

/// Rules of a format 1 or 2 (chain) context subtable. Sequences are backtrack, input and lookahead.
pub const Rules = struct {
    subtable: Layout.Subtable,
    set_index: usize = 0,
    rule_index: usize = 0,

    pub fn init(subtable: Layout.Subtable) Rules {
        return .{ .subtable = subtable };
    }

    fn setsPosition(self: *const Rules) usize {
        return switch (self.subtable.kind) {
            .context => switch (self.subtable.format) {
                1 => 4,
                else => 6,
            },
            else => switch (self.subtable.format) {
                1 => 4,
                else => 10,
            },
        };
    }

    pub fn next(self: *Rules) ?Rule {
        const reader = self.subtable.reader;
        const position = self.setsPosition();
        const set_count = reader.u16At(position) catch return null;
        while (self.set_index < set_count) {
            const set = offsetTarget(reader, position + 2 + self.set_index * 2) orelse {
                self.set_index += 1;
                self.rule_index = 0;
                continue;
            };
            const count = set.u16At(0) catch 0;
            if (self.rule_index >= count) {
                self.set_index += 1;
                self.rule_index = 0;
                continue;
            }
            const rule = offsetTarget(set, 2 + self.rule_index * 2);
            self.rule_index += 1;
            const table = rule orelse continue;
            return parseRule(self.subtable.kind, table, self.set_index) orelse continue;
        }
        return null;
    }
};

fn parseRule(kind: Layout.Kind, rule: Reader, first_class: usize) ?Rule {
    switch (kind) {
        .context => {
            const glyph_count = rule.u16At(0) catch return null;
            const lookup_count = rule.u16At(2) catch return null;
            const input = @as(usize, glyph_count) -| 1;
            return .{
                .first_class = @intCast(first_class),
                .sequences = .{ .{ .reader = rule, .position = 4, .count = 0 }, .{ .reader = rule, .position = 4, .count = input }, .{ .reader = rule, .position = 4, .count = 0 } },
                .lookups = .{ .reader = rule, .position = 4 + input * 2, .count = lookup_count },
            };
        },
        else => {
            const backtrack = rule.u16At(0) catch return null;
            var position: usize = 2 + @as(usize, backtrack) * 2;
            const input_count = rule.u16At(position) catch return null;
            const input_position = position + 2;
            const input = @as(usize, input_count) -| 1;
            position = input_position + input * 2;
            const lookahead = rule.u16At(position) catch return null;
            const lookahead_position = position + 2;
            position = lookahead_position + @as(usize, lookahead) * 2;
            const lookup_count = rule.u16At(position) catch return null;
            return .{
                .first_class = @intCast(first_class),
                .sequences = .{
                    .{ .reader = rule, .position = 2, .count = backtrack },
                    .{ .reader = rule, .position = input_position, .count = input },
                    .{ .reader = rule, .position = lookahead_position, .count = lookahead },
                },
                .lookups = .{ .reader = rule, .position = position + 2, .count = lookup_count },
            };
        },
    }
}

/// Lookup indices referenced by a context subtable's sequence lookup records.
pub const NestedLookups = struct {
    subtable: Layout.Subtable,
    rules: Rules,
    current: ?Sequence = null,
    index: usize = 0,
    done_format3: bool = false,

    pub fn init(subtable: Layout.Subtable) NestedLookups {
        return .{ .subtable = subtable, .rules = .init(subtable) };
    }

    pub fn next(self: *NestedLookups) ?u16 {
        switch (self.subtable.kind) {
            .context, .chain_context => {},
            else => return null,
        }
        if (self.subtable.format == 3) {
            if (!self.done_format3) {
                self.done_format3 = true;
                self.current = format3Records(self.subtable);
            }
        }
        while (true) {
            if (self.current) |sequence| {
                if (self.index < sequence.count) {
                    const value = sequence.reader.u16At(sequence.position + self.index * 4 + 2) catch return null;
                    self.index += 1;
                    return value;
                }
            }
            if (self.subtable.format == 3) return null;
            const rule = self.rules.next() orelse return null;
            self.current = rule.lookups;
            self.index = 0;
        }
    }
};

fn format3Records(subtable: Layout.Subtable) ?Sequence {
    const reader = subtable.reader;
    switch (subtable.kind) {
        .context => {
            const glyph_count = reader.u16At(2) catch return null;
            const lookup_count = reader.u16At(4) catch return null;
            return .{ .reader = reader, .position = 6 + @as(usize, glyph_count) * 2, .count = lookup_count };
        },
        else => {
            const position = 4 + @as(usize, subtable.backtrack_count) * 2 + 2 + @as(usize, subtable.input_count) * 2 + 2 + @as(usize, subtable.lookahead_count) * 2;
            const lookup_count = reader.u16At(position) catch return null;
            return .{ .reader = reader, .position = position + 2, .count = lookup_count };
        },
    }
}

pub const ContextLimits = struct {
    backtrack: u32 = 0,
    input: u32 = 1,
    lookahead: u32 = 0,

    fn merge(self: *ContextLimits, backtrack: u32, input: u32, lookahead: u32) void {
        self.backtrack = @max(self.backtrack, backtrack);
        self.input = @max(self.input, input);
        self.lookahead = @max(self.lookahead, lookahead);
    }
};

/// The longest backtrack, input and lookahead any reachable rule can match, from the rules themselves.
pub fn contextLimits(program: *const FontProgram, lookups: anytype, apply_kern: bool) ContextLimits {
    var limits: ContextLimits = .{};
    if (apply_kern) limits.merge(0, 2, 0);
    var visited: [2]std.StaticBitSet(1 << 16) = .{ .empty, .empty };
    for (lookups, 0..) |list, table_index| {
        for (list) |lookup| collectLimits(program, table_index, lookup.index, &visited, 0, &limits);
    }
    return limits;
}

fn collectLimits(program: *const FontProgram, table_index: usize, index: u16, visited: *[2]std.StaticBitSet(1 << 16), depth: u32, limits: *ContextLimits) void {
    if (depth > nesting_max or visited[table_index].isSet(index)) return;
    visited[table_index].set(index);
    const layout = layoutOf(program, table_index);
    if (index >= layout.lookups.len) return;
    for (layout.lookups[index].subtables) |subtable| {
        subtableLimits(subtable, limits);
        var records = NestedLookups.init(subtable);
        while (records.next()) |nested| collectLimits(program, table_index, nested, visited, depth + 1, limits);
    }
}

fn subtableLimits(subtable: Layout.Subtable, limits: *ContextLimits) void {
    switch (subtable.kind) {
        .none, .single_subst, .multiple_subst, .alternate_subst, .single_pos => {},
        .pair_pos => limits.merge(0, 2, 0),
        .cursive_pos, .mark_base_pos, .mark_ligature_pos, .mark_mark_pos => limits.merge(1, 1, 0),
        .reverse_chain_subst => limits.merge(subtable.backtrack_count, 1, subtable.lookahead_count),
        .ligature_subst => {
            const reader = subtable.reader;
            const set_count = reader.u16At(4) catch return;
            for (0..set_count) |set_index| {
                const set = offsetTarget(reader, 6 + set_index * 2) orelse continue;
                const count = set.u16At(0) catch continue;
                for (0..count) |ligature_index| {
                    const ligature = offsetTarget(set, 2 + ligature_index * 2) orelse continue;
                    limits.merge(0, ligature.u16At(2) catch 0, 0);
                }
            }
        },
        .context, .chain_context => switch (subtable.format) {
            3 => limits.merge(subtable.backtrack_count, subtable.input_count, subtable.lookahead_count),
            else => {
                var rules = Rules.init(subtable);
                while (rules.next()) |rule| {
                    limits.merge(@intCast(rule.sequences[0].count), @intCast(rule.sequences[1].count + 1), @intCast(rule.sequences[2].count));
                }
            },
        },
    }
}
