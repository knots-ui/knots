//! A compiled GSUB or GPOS table. Lists are read lazily with bounds checks,
//! lookups are validated and unwrapped once, and every match predicate is
//! registered with the glyph partition.

const std = @import("std");
const Reader = @import("Reader.zig");
const Partition = @import("Partition.zig");
const coverage = @import("coverage.zig");
const class_def = @import("class_def.zig");

present: bool,
script_list: Reader,
feature_list: Reader,
feature_variations: ?Reader,
lookups: []const Lookup,

const Layout = @This();

pub const Table = enum { gsub, gpos };

pub const no_index: u16 = 0xFFFF;

pub const empty: Layout = .{
    .present = false,
    .script_list = .{ .bytes = &.{} },
    .feature_list = .{ .bytes = &.{} },
    .feature_variations = null,
    .lookups = &.{},
};

pub const Kind = enum(u8) {
    none,
    single_subst,
    multiple_subst,
    alternate_subst,
    ligature_subst,
    reverse_chain_subst,
    single_pos,
    pair_pos,
    cursive_pos,
    mark_base_pos,
    mark_ligature_pos,
    mark_mark_pos,
    context,
    chain_context,
};

pub const flag_right_to_left: u16 = 0x0001;
pub const flag_ignore_base_glyphs: u16 = 0x0002;
pub const flag_ignore_ligatures: u16 = 0x0004;
pub const flag_ignore_marks: u16 = 0x0008;
pub const flag_use_mark_filtering_set: u16 = 0x0010;
pub const flag_ignore_flags: u16 = 0x000E;
pub const flag_mark_attachment_type: u16 = 0xFF00;

pub const Lookup = struct {
    kind: Kind,
    flags: u16,
    mark_filtering_set: u16,
    subtables: []const Subtable,

    pub fn isReverse(self: *const Lookup) bool {
        return self.kind == .reverse_chain_subst;
    }
};

pub const Subtable = struct {
    reader: Reader,
    kind: Kind,
    format: u16,
    coverage: Reader,
    coverage_id: Partition.Id,
    predicates: []const Partition.Id = &.{},
    backtrack_count: u16 = 0,
    input_count: u16 = 0,
    lookahead_count: u16 = 0,
    data: Data = .{},
};

/// Native-endian copies of everything the shaper reads from a subtable, so applying
/// a lookup does no bounds checks, byte swaps or offset chasing.
pub const Data = struct {
    cover: Cover = .{},
    /// Rule ranges of format 1 and 2 (chain) context subtables, by coverage index or class.
    /// Also ligature ranges by coverage index, and sequence ranges of multiple and alternate subtables.
    sets: []const u32 = &.{},
    rules: []const Rule = &.{},
    ligatures: []const Ligature = &.{},
    /// Glyph ids and class values that rules, ligatures and substitutions point into.
    values: []const u16 = &.{},
    records: []const Record = &.{},
    delta: u16 = 0,
    /// Pair positioning: value presence, format 1 pairs by set, format 2 class matrix.
    has_first: bool = false,
    has_second: bool = false,
    pairs: []const Pair = &.{},
    class1_count: u16 = 0,
    class2_count: u16 = 0,
    matrix: []const [2]Value = &.{},
    /// Single positioning values, one for format 1.
    single: []const Value = &.{},

    pub fn set(self: *const Data, index: u32) []const u32 {
        if (index + 1 >= self.sets.len) return &.{};
        return self.sets[index..][0..2];
    }

    pub fn ruleRange(self: *const Data, index: u32) []const Rule {
        const bounds = self.set(index);
        if (bounds.len == 0) return &.{};
        return self.rules[bounds[0]..bounds[1]];
    }

    pub fn ligatureRange(self: *const Data, index: u32) []const Ligature {
        const bounds = self.set(index);
        if (bounds.len == 0) return &.{};
        return self.ligatures[bounds[0]..bounds[1]];
    }

    pub fn sequence(self: *const Data, index: u32) []const u16 {
        const bounds = self.set(index);
        if (bounds.len == 0) return &.{};
        return self.values[bounds[0]..bounds[1]];
    }

    pub fn backtrack(self: *const Data, rule: Rule) []const u16 {
        return self.values[rule.start..][0..rule.backtrack_count];
    }

    pub fn input(self: *const Data, rule: Rule) []const u16 {
        return self.values[rule.start + rule.backtrack_count ..][0..rule.input_count -| 1];
    }

    pub fn lookahead(self: *const Data, rule: Rule) []const u16 {
        return self.values[rule.start + rule.backtrack_count + (rule.input_count -| 1) ..][0..rule.lookahead_count];
    }

    pub fn ruleRecords(self: *const Data, rule: Rule) []const Record {
        return self.records[rule.records..][0..rule.record_count];
    }

    pub fn components(self: *const Data, ligature: Ligature) []const u16 {
        return self.values[ligature.components..][0..ligature.component_count -| 1];
    }
};

/// A coverage table decoded in file order, searched exactly like the original.
pub const Cover = struct {
    glyphs: []const u16 = &.{},
    ranges: []const CoverRange = &.{},
    sorted: bool = false,

    /// The same probe order as `coverage.index`, so unsorted tables give the same answers.
    pub fn index(self: *const Cover, glyph: u32) u32 {
        if (self.ranges.len == 0) {
            const glyphs = self.glyphs;
            if (glyphs.len <= 8) {
                // Tiny sorted lists, the common case in code fonts' calt rules.
                if (self.sorted) {
                    for (glyphs, 0..) |value, i| {
                        if (value == glyph) return @intCast(i);
                    }
                    return coverage.not_covered;
                }
            }
            var low: i32 = 0;
            var high: i32 = @as(i32, @intCast(glyphs.len)) - 1;
            while (low <= high) {
                const mid: u32 = @intCast(@divTrunc(low + high, 2));
                const value = glyphs[mid];
                if (glyph < value) {
                    high = @as(i32, @intCast(mid)) - 1;
                } else if (glyph > value) {
                    low = @as(i32, @intCast(mid)) + 1;
                } else return mid;
            }
            return coverage.not_covered;
        }
        const ranges = self.ranges;
        var low: i32 = 0;
        var high: i32 = @as(i32, @intCast(ranges.len)) - 1;
        while (low <= high) {
            const mid: u32 = @intCast(@divTrunc(low + high, 2));
            const range = ranges[mid];
            if (glyph < range.first) {
                high = @as(i32, @intCast(mid)) - 1;
            } else if (glyph > range.last) {
                low = @as(i32, @intCast(mid)) + 1;
            } else return range.start + (glyph - range.first);
        }
        return coverage.not_covered;
    }
};

pub const CoverRange = extern struct { first: u16, last: u16, start: u32 };

/// Offsets into `Data.values` and `Data.records`. Backtrack, input after the first glyph and lookahead are stored back to back.
pub const Rule = extern struct {
    start: u32,
    records: u32,
    backtrack_count: u16,
    input_count: u16,
    lookahead_count: u16,
    record_count: u16,

    pub const empty: Rule = .{ .start = 0, .records = 0, .backtrack_count = 0, .input_count = 0, .lookahead_count = 0, .record_count = 0 };
};

pub const Record = extern struct { sequence: u16, lookup: u16 };

/// `component_count` includes the first glyph, which the coverage matched.
pub const Ligature = extern struct {
    glyph: u16,
    component_count: u16,
    components: u32,

    /// A null offset in the ligature set, kept so set sizes match the font.
    pub const absent: u16 = std.math.maxInt(u16);
};

/// A decoded ValueRecord. `nonzero` is whether any field the format carries is nonzero.
pub const Value = extern struct {
    x_offset: i16 = 0,
    y_offset: i16 = 0,
    x_advance: i16 = 0,
    nonzero: bool = false,
};

pub const Pair = extern struct { second: u16, first_value: Value, second_value: Value };

comptime {
    std.debug.assert(@sizeOf(Rule) == 16);
    std.debug.assert(@sizeOf(Value) == 8);
}

pub fn compile(arena: std.mem.Allocator, table: ?Reader, which: Table, builder: *Partition.Builder) !Layout {
    const reader = table orelse return empty;
    const header = parseHeader(reader) catch return empty;
    var compiler: Compiler = .{ .arena = arena, .builder = builder, .which = which };
    const lookups = try compiler.lookupList(header.lookup_list);
    return .{
        .present = true,
        .script_list = header.script_list,
        .feature_list = header.feature_list,
        .feature_variations = header.feature_variations,
        .lookups = lookups,
    };
}

const Header = struct {
    script_list: Reader,
    feature_list: Reader,
    lookup_list: Reader,
    feature_variations: ?Reader,
};

fn parseHeader(table: Reader) !Header {
    const major = try table.u16At(0);
    const minor = try table.u16At(2);
    if (major != 1) return error.OutOfBounds;
    const script_list = try table.sub(try table.u16At(4));
    const feature_list = try table.sub(try table.u16At(6));
    const lookup_list = try table.sub(try table.u16At(8));
    var feature_variations: ?Reader = null;
    if (minor >= 1) feature_variations = try table.offset32(10);
    _ = try script_list.u16At(0);
    _ = try feature_list.u16At(0);
    _ = try lookup_list.u16At(0);
    return .{ .script_list = script_list, .feature_list = feature_list, .lookup_list = lookup_list, .feature_variations = feature_variations };
}

fn kindOf(which: Table, lookup_type: u16) ?Kind {
    return switch (which) {
        .gsub => switch (lookup_type) {
            1 => .single_subst,
            2 => .multiple_subst,
            3 => .alternate_subst,
            4 => .ligature_subst,
            5 => .context,
            6 => .chain_context,
            8 => .reverse_chain_subst,
            else => null,
        },
        .gpos => switch (lookup_type) {
            1 => .single_pos,
            2 => .pair_pos,
            3 => .cursive_pos,
            4 => .mark_base_pos,
            5 => .mark_ligature_pos,
            6 => .mark_mark_pos,
            7 => .context,
            8 => .chain_context,
            else => null,
        },
    };
}

fn extensionType(which: Table) u16 {
    return switch (which) {
        .gsub => 7,
        .gpos => 9,
    };
}

pub fn valueRecordSize(format: u16) usize {
    return @as(usize, @popCount(format & 0xFF)) * 2;
}

const Compiler = struct {
    arena: std.mem.Allocator,
    builder: *Partition.Builder,
    which: Table,

    fn lookupList(self: *Compiler, list: Reader) ![]const Lookup {
        const count = list.u16At(0) catch return &.{};
        const lookups = try self.arena.alloc(Lookup, count);
        for (lookups, 0..) |*lookup, index| {
            lookup.* = .{ .kind = .none, .flags = 0, .mark_filtering_set = no_index, .subtables = &.{} };
            const offset = list.u16At(2 + index * 2) catch continue;
            const reader = list.sub(offset) catch continue;
            lookup.* = try self.compileLookup(reader);
        }
        return lookups;
    }

    fn compileLookup(self: *Compiler, reader: Reader) !Lookup {
        var result: Lookup = .{ .kind = .none, .flags = 0, .mark_filtering_set = no_index, .subtables = &.{} };
        const lookup_type = reader.u16At(0) catch return result;
        const flags = reader.u16At(2) catch return result;
        const count = reader.u16At(4) catch return result;
        if (!reader.has(6, @as(usize, count) * 2)) return result;
        var mark_filtering_set: u16 = no_index;
        if (flags & flag_use_mark_filtering_set != 0) {
            mark_filtering_set = reader.u16At(6 + @as(usize, count) * 2) catch return result;
        }
        result.flags = flags;
        result.mark_filtering_set = mark_filtering_set;

        const is_extension = lookup_type == extensionType(self.which);
        var effective_type = lookup_type;
        if (is_extension) {
            if (count == 0) return result;
            effective_type = extensionTargetType(reader, 0) orelse return result;
            for (0..count) |index| {
                if (extensionTargetType(reader, index) != effective_type) return result;
            }
        }
        const kind = kindOf(self.which, effective_type) orelse return result;
        result.kind = kind;

        var subtables: std.ArrayList(Subtable) = .empty;
        for (0..count) |index| {
            const offset = reader.u16At(6 + index * 2) catch continue;
            var subtable = reader.sub(offset) catch continue;
            if (is_extension) subtable = extensionTarget(subtable) orelse continue;
            if (try self.compileSubtable(kind, subtable)) |compiled| {
                var with_data = compiled;
                with_data.data = try decode(self.arena, compiled);
                try subtables.append(self.arena, with_data);
            }
        }
        result.subtables = subtables.items;
        return result;
    }

    fn extensionTargetType(reader: Reader, index: usize) ?u16 {
        const offset = reader.u16At(6 + index * 2) catch return null;
        const extension = reader.sub(offset) catch return null;
        const format = extension.u16At(0) catch return null;
        if (format != 1) return null;
        return extension.u16At(2) catch null;
    }

    fn extensionTarget(extension: Reader) ?Reader {
        const offset = extension.u32At(4) catch return null;
        return extension.sub(offset) catch null;
    }

    fn coverageAt(self: *Compiler, base: Reader, offset_position: usize) !?struct { Reader, Partition.Id } {
        const offset = base.u16At(offset_position) catch return null;
        if (offset == 0) return null;
        const table = base.sub(offset) catch return null;
        if (!coverage.validate(table)) return null;
        return .{ table, try self.builder.coverageId(table) };
    }

    fn classDefAt(self: *Compiler, base: Reader, offset_position: usize) !?Partition.Id {
        const offset = base.u16At(offset_position) catch return null;
        if (offset == 0) return try self.emptyClassDef();
        const table = base.sub(offset) catch return null;
        if (!class_def.validate(table)) return null;
        return try self.builder.classDefId(table);
    }

    fn emptyClassDef(self: *Compiler) !Partition.Id {
        return self.builder.classDefId(Reader.init(&empty_class_def));
    }

    fn compileSubtable(self: *Compiler, kind: Kind, reader: Reader) !?Subtable {
        const format = reader.u16At(0) catch return null;
        return switch (kind) {
            .none => null,
            .single_subst => self.singleSubst(reader, format),
            .multiple_subst, .alternate_subst => self.sequenceSubst(kind, reader, format),
            .ligature_subst => self.ligatureSubst(reader, format),
            .reverse_chain_subst => self.reverseChain(reader, format),
            .single_pos => self.singlePos(reader, format),
            .pair_pos => self.pairPos(reader, format),
            .cursive_pos => self.cursivePos(reader, format),
            .mark_base_pos, .mark_ligature_pos, .mark_mark_pos => self.markPos(kind, reader, format),
            .context => self.context(reader, format),
            .chain_context => self.chainContext(reader, format),
        };
    }

    fn simple(kind: Kind, reader: Reader, format: u16, primary: struct { Reader, Partition.Id }) Subtable {
        return .{ .reader = reader, .kind = kind, .format = format, .coverage = primary[0], .coverage_id = primary[1] };
    }

    fn singleSubst(self: *Compiler, reader: Reader, format: u16) !?Subtable {
        const primary = try self.coverageAt(reader, 2) orelse return null;
        switch (format) {
            1 => if (!reader.has(0, 6)) return null,
            2 => {
                const count = reader.u16At(4) catch return null;
                if (!reader.has(6, @as(usize, count) * 2)) return null;
            },
            else => return null,
        }
        return simple(.single_subst, reader, format, primary);
    }

    fn sequenceSubst(self: *Compiler, kind: Kind, reader: Reader, format: u16) !?Subtable {
        if (format != 1) return null;
        const primary = try self.coverageAt(reader, 2) orelse return null;
        const count = reader.u16At(4) catch return null;
        if (!reader.has(6, @as(usize, count) * 2)) return null;
        for (0..count) |index| {
            const offset = reader.u16At(6 + index * 2) catch return null;
            if (offset == 0) continue;
            const sequence = reader.sub(offset) catch return null;
            const glyphs = sequence.u16At(0) catch return null;
            if (!sequence.has(2, @as(usize, glyphs) * 2)) return null;
        }
        return simple(kind, reader, format, primary);
    }

    fn ligatureSubst(self: *Compiler, reader: Reader, format: u16) !?Subtable {
        if (format != 1) return null;
        const primary = try self.coverageAt(reader, 2) orelse return null;
        const set_count = reader.u16At(4) catch return null;
        if (!reader.has(6, @as(usize, set_count) * 2)) return null;
        for (0..set_count) |set_index| {
            const set_offset = reader.u16At(6 + set_index * 2) catch return null;
            if (set_offset == 0) continue;
            const set = reader.sub(set_offset) catch return null;
            const ligature_count = set.u16At(0) catch return null;
            if (!set.has(2, @as(usize, ligature_count) * 2)) return null;
            for (0..ligature_count) |ligature_index| {
                const ligature_offset = set.u16At(2 + ligature_index * 2) catch return null;
                if (ligature_offset == 0) continue;
                const ligature = set.sub(ligature_offset) catch return null;
                const component_count = ligature.u16At(2) catch return null;
                if (component_count == 0) continue;
                if (!ligature.has(4, (@as(usize, component_count) - 1) * 2)) return null;
                for (1..component_count) |component| {
                    _ = try self.builder.glyphId(ligature.u16At(4 + (component - 1) * 2) catch return null);
                }
            }
        }
        return simple(.ligature_subst, reader, format, primary);
    }

    fn coverageList(self: *Compiler, reader: Reader, position: usize, count: u16, out: *std.ArrayList(Partition.Id)) !bool {
        if (!reader.has(position, @as(usize, count) * 2)) return false;
        for (0..count) |index| {
            const entry = try self.coverageAt(reader, position + index * 2) orelse return false;
            try out.append(self.arena, entry[1]);
        }
        return true;
    }

    fn reverseChain(self: *Compiler, reader: Reader, format: u16) !?Subtable {
        if (format != 1) return null;
        const primary = try self.coverageAt(reader, 2) orelse return null;
        var predicates: std.ArrayList(Partition.Id) = .empty;
        const backtrack_count = reader.u16At(4) catch return null;
        if (!try self.coverageList(reader, 6, backtrack_count, &predicates)) return null;
        const lookahead_position = 6 + @as(usize, backtrack_count) * 2;
        const lookahead_count = reader.u16At(lookahead_position) catch return null;
        if (!try self.coverageList(reader, lookahead_position + 2, lookahead_count, &predicates)) return null;
        const substitutes_position = lookahead_position + 2 + @as(usize, lookahead_count) * 2;
        const substitute_count = reader.u16At(substitutes_position) catch return null;
        if (!reader.has(substitutes_position + 2, @as(usize, substitute_count) * 2)) return null;
        var result = simple(.reverse_chain_subst, reader, format, primary);
        result.predicates = predicates.items;
        result.backtrack_count = backtrack_count;
        result.lookahead_count = lookahead_count;
        return result;
    }

    fn singlePos(self: *Compiler, reader: Reader, format: u16) !?Subtable {
        const primary = try self.coverageAt(reader, 2) orelse return null;
        const value_format = reader.u16At(4) catch return null;
        const size = valueRecordSize(value_format);
        switch (format) {
            1 => if (!reader.has(6, size)) return null,
            2 => {
                const count = reader.u16At(6) catch return null;
                if (!reader.has(8, @as(usize, count) * size)) return null;
            },
            else => return null,
        }
        return simple(.single_pos, reader, format, primary);
    }

    fn pairPos(self: *Compiler, reader: Reader, format: u16) !?Subtable {
        const primary = try self.coverageAt(reader, 2) orelse return null;
        const format1 = reader.u16At(4) catch return null;
        const format2 = reader.u16At(6) catch return null;
        const record_size = valueRecordSize(format1) + valueRecordSize(format2);
        switch (format) {
            1 => {
                const set_count = reader.u16At(8) catch return null;
                if (!reader.has(10, @as(usize, set_count) * 2)) return null;
                for (0..set_count) |set_index| {
                    const offset = reader.u16At(10 + set_index * 2) catch return null;
                    const set = reader.sub(offset) catch return null;
                    const count = set.u16At(0) catch return null;
                    if (!set.has(2, @as(usize, count) * (2 + record_size))) return null;
                    for (0..count) |pair| _ = try self.builder.glyphId(set.u16At(2 + pair * (2 + record_size)) catch return null);
                }
                return simple(.pair_pos, reader, format, primary);
            },
            2 => {
                const first = try self.classDefAt(reader, 8) orelse return null;
                const second = try self.classDefAt(reader, 10) orelse return null;
                const class1_count = reader.u16At(12) catch return null;
                const class2_count = reader.u16At(14) catch return null;
                if (!reader.has(16, @as(usize, class1_count) * class2_count * record_size)) return null;
                var result = simple(.pair_pos, reader, format, primary);
                result.predicates = try self.arena.dupe(Partition.Id, &.{ first, second });
                return result;
            },
            else => return null,
        }
    }

    fn cursivePos(self: *Compiler, reader: Reader, format: u16) !?Subtable {
        if (format != 1) return null;
        const primary = try self.coverageAt(reader, 2) orelse return null;
        const count = reader.u16At(4) catch return null;
        if (!reader.has(6, @as(usize, count) * 4)) return null;
        return simple(.cursive_pos, reader, format, primary);
    }

    fn markPos(self: *Compiler, kind: Kind, reader: Reader, format: u16) !?Subtable {
        if (format != 1) return null;
        const primary = try self.coverageAt(reader, 2) orelse return null;
        const second = try self.coverageAt(reader, 4) orelse return null;
        const class_count = reader.u16At(6) catch return null;
        const mark_array = reader.sub(reader.u16At(8) catch return null) catch return null;
        const mark_count = mark_array.u16At(0) catch return null;
        if (!mark_array.has(2, @as(usize, mark_count) * 4)) return null;
        const attach_array = reader.sub(reader.u16At(10) catch return null) catch return null;
        const attach_count = attach_array.u16At(0) catch return null;
        switch (kind) {
            .mark_ligature_pos => {
                if (!attach_array.has(2, @as(usize, attach_count) * 2)) return null;
                for (0..attach_count) |index| {
                    const offset = attach_array.u16At(2 + index * 2) catch return null;
                    const attach = attach_array.sub(offset) catch return null;
                    const components = attach.u16At(0) catch return null;
                    if (!attach.has(2, @as(usize, components) * class_count * 2)) return null;
                }
            },
            else => if (!attach_array.has(2, @as(usize, attach_count) * class_count * 2)) return null,
        }
        var result = simple(kind, reader, format, primary);
        result.predicates = try self.arena.dupe(Partition.Id, &.{second[1]});
        return result;
    }

    fn ruleSets(self: *Compiler, reader: Reader, position: usize, chained: bool, name_glyphs: bool) !bool {
        const set_count = reader.u16At(position) catch return false;
        if (!reader.has(position + 2, @as(usize, set_count) * 2)) return false;
        for (0..set_count) |set_index| {
            const set_offset = reader.u16At(position + 2 + set_index * 2) catch return false;
            if (set_offset == 0) continue;
            const set = reader.sub(set_offset) catch return false;
            const rule_count = set.u16At(0) catch return false;
            if (!set.has(2, @as(usize, rule_count) * 2)) return false;
            for (0..rule_count) |rule_index| {
                const rule_offset = set.u16At(2 + rule_index * 2) catch return false;
                if (rule_offset == 0) continue;
                const rule_table = set.sub(rule_offset) catch return false;
                const valid = switch (chained) {
                    true => try self.chainRule(rule_table, name_glyphs),
                    false => try self.rule(rule_table, name_glyphs),
                };
                if (!valid) return false;
            }
        }
        return true;
    }

    fn nameGlyphs(self: *Compiler, reader: Reader, position: usize, count: usize) !void {
        for (0..count) |index| _ = try self.builder.glyphId(reader.u16At(position + index * 2) catch return);
    }

    fn rule(self: *Compiler, reader: Reader, name_glyphs: bool) !bool {
        const glyph_count = reader.u16At(0) catch return false;
        const lookup_count = reader.u16At(2) catch return false;
        const input = @as(usize, glyph_count) -| 1;
        if (!reader.has(4, input * 2 + @as(usize, lookup_count) * 4)) return false;
        if (name_glyphs) try self.nameGlyphs(reader, 4, input);
        return true;
    }

    fn chainRule(self: *Compiler, reader: Reader, name_glyphs: bool) !bool {
        const backtrack = reader.u16At(0) catch return false;
        var position: usize = 2 + @as(usize, backtrack) * 2;
        const input_count = reader.u16At(position) catch return false;
        const input_position = position + 2;
        position = input_position + (@as(usize, input_count) -| 1) * 2;
        const lookahead = reader.u16At(position) catch return false;
        const lookahead_position = position + 2;
        position = lookahead_position + @as(usize, lookahead) * 2;
        const lookup_count = reader.u16At(position) catch return false;
        if (!reader.has(position + 2, @as(usize, lookup_count) * 4)) return false;
        if (name_glyphs) {
            try self.nameGlyphs(reader, 2, backtrack);
            try self.nameGlyphs(reader, input_position, @as(usize, input_count) -| 1);
            try self.nameGlyphs(reader, lookahead_position, lookahead);
        }
        return true;
    }

    fn context(self: *Compiler, reader: Reader, format: u16) !?Subtable {
        switch (format) {
            1 => {
                const primary = try self.coverageAt(reader, 2) orelse return null;
                if (!try self.ruleSets(reader, 4, false, true)) return null;
                return simple(.context, reader, format, primary);
            },
            2 => {
                const primary = try self.coverageAt(reader, 2) orelse return null;
                const classes = try self.classDefAt(reader, 4) orelse return null;
                if (!try self.ruleSets(reader, 6, false, false)) return null;
                var result = simple(.context, reader, format, primary);
                result.predicates = try self.arena.dupe(Partition.Id, &.{classes});
                return result;
            },
            3 => {
                const glyph_count = reader.u16At(2) catch return null;
                const lookup_count = reader.u16At(4) catch return null;
                if (glyph_count == 0) return null;
                if (!reader.has(6, @as(usize, glyph_count) * 2 + @as(usize, lookup_count) * 4)) return null;
                var predicates: std.ArrayList(Partition.Id) = .empty;
                if (!try self.coverageList(reader, 6, glyph_count, &predicates)) return null;
                const primary = try self.coverageAt(reader, 6) orelse return null;
                var result = simple(.context, reader, format, primary);
                result.predicates = predicates.items;
                result.input_count = glyph_count;
                return result;
            },
            else => return null,
        }
    }

    fn chainContext(self: *Compiler, reader: Reader, format: u16) !?Subtable {
        switch (format) {
            1 => {
                const primary = try self.coverageAt(reader, 2) orelse return null;
                if (!try self.ruleSets(reader, 4, true, true)) return null;
                return simple(.chain_context, reader, format, primary);
            },
            2 => {
                const primary = try self.coverageAt(reader, 2) orelse return null;
                const backtrack = try self.classDefAt(reader, 4) orelse return null;
                const input = try self.classDefAt(reader, 6) orelse return null;
                const lookahead = try self.classDefAt(reader, 8) orelse return null;
                if (!try self.ruleSets(reader, 10, true, false)) return null;
                var result = simple(.chain_context, reader, format, primary);
                result.predicates = try self.arena.dupe(Partition.Id, &.{ backtrack, input, lookahead });
                return result;
            },
            3 => {
                var predicates: std.ArrayList(Partition.Id) = .empty;
                const backtrack_count = reader.u16At(2) catch return null;
                if (!try self.coverageList(reader, 4, backtrack_count, &predicates)) return null;
                const input_position = 4 + @as(usize, backtrack_count) * 2;
                const input_count = reader.u16At(input_position) catch return null;
                if (input_count == 0) return null;
                if (!try self.coverageList(reader, input_position + 2, input_count, &predicates)) return null;
                const lookahead_position = input_position + 2 + @as(usize, input_count) * 2;
                const lookahead_count = reader.u16At(lookahead_position) catch return null;
                if (!try self.coverageList(reader, lookahead_position + 2, lookahead_count, &predicates)) return null;
                const records_position = lookahead_position + 2 + @as(usize, lookahead_count) * 2;
                const lookup_count = reader.u16At(records_position) catch return null;
                if (!reader.has(records_position + 2, @as(usize, lookup_count) * 4)) return null;
                const primary = try self.coverageAt(reader, input_position + 2) orelse return null;
                var result = simple(.chain_context, reader, format, primary);
                result.predicates = predicates.items;
                result.backtrack_count = backtrack_count;
                result.input_count = input_count;
                result.lookahead_count = lookahead_count;
                return result;
            },
            else => return null,
        }
    }
};

const empty_class_def = [_]u8{ 0, 2, 0, 0 };

/// Builds `Data` for a validated subtable.
const Decoder = struct {
    arena: std.mem.Allocator,
    sets: std.ArrayList(u32) = .empty,
    rules: std.ArrayList(Rule) = .empty,
    ligatures: std.ArrayList(Ligature) = .empty,
    values: std.ArrayList(u16) = .empty,
    records: std.ArrayList(Record) = .empty,

    fn glyphs(self: *Decoder, reader: Reader, position: usize, count: usize) !void {
        try self.values.ensureUnusedCapacity(self.arena, count);
        for (0..count) |index| self.values.appendAssumeCapacity(reader.u16Unchecked(position + index * 2));
    }

    fn lookupRecords(self: *Decoder, reader: Reader, position: usize, count: usize) !void {
        try self.records.ensureUnusedCapacity(self.arena, count);
        for (0..count) |index| self.records.appendAssumeCapacity(.{
            .sequence = reader.u16Unchecked(position + index * 4),
            .lookup = reader.u16Unchecked(position + index * 4 + 2),
        });
    }

    fn mark(self: *Decoder) !void {
        try self.sets.append(self.arena, 0);
    }

    fn data(self: *Decoder, cover: Cover) Data {
        return .{
            .cover = cover,
            .sets = self.sets.items,
            .rules = self.rules.items,
            .ligatures = self.ligatures.items,
            .values = self.values.items,
            .records = self.records.items,
        };
    }

    /// Rule sets at `position`: a count, then offsets to sets of offsets to rules.
    fn ruleSets(self: *Decoder, reader: Reader, position: usize, chained: bool) !void {
        const set_count = reader.u16Unchecked(position);
        try self.sets.ensureTotalCapacity(self.arena, @as(usize, set_count) + 1);
        for (0..set_count) |set_index| {
            self.sets.appendAssumeCapacity(@intCast(self.rules.items.len));
            const set_offset = reader.u16Unchecked(position + 2 + set_index * 2);
            if (set_offset == 0) continue;
            const set = Reader{ .bytes = reader.bytes[set_offset..] };
            const rule_count = set.u16Unchecked(0);
            for (0..rule_count) |rule_index| {
                const rule_offset = set.u16Unchecked(2 + rule_index * 2);
                if (rule_offset == 0) {
                    try self.rules.append(self.arena, .empty);
                    continue;
                }
                const table = Reader{ .bytes = set.bytes[rule_offset..] };
                try self.rule(table, chained);
            }
        }
        self.sets.appendAssumeCapacity(@intCast(self.rules.items.len));
    }

    fn rule(self: *Decoder, table: Reader, chained: bool) !void {
        var result: Rule = .{ .start = @intCast(self.values.items.len), .records = @intCast(self.records.items.len), .backtrack_count = 0, .input_count = 0, .lookahead_count = 0, .record_count = 0 };
        if (!chained) {
            result.input_count = table.u16Unchecked(0);
            result.record_count = table.u16Unchecked(2);
            const input_len = @as(usize, result.input_count) -| 1;
            try self.glyphs(table, 4, input_len);
            try self.lookupRecords(table, 4 + input_len * 2, result.record_count);
            try self.rules.append(self.arena, result);
            return;
        }
        result.backtrack_count = table.u16Unchecked(0);
        try self.glyphs(table, 2, result.backtrack_count);
        var position: usize = 2 + @as(usize, result.backtrack_count) * 2;
        result.input_count = table.u16Unchecked(position);
        const input_len = @as(usize, result.input_count) -| 1;
        try self.glyphs(table, position + 2, input_len);
        position += 2 + input_len * 2;
        result.lookahead_count = table.u16Unchecked(position);
        try self.glyphs(table, position + 2, result.lookahead_count);
        position += 2 + @as(usize, result.lookahead_count) * 2;
        result.record_count = table.u16Unchecked(position);
        try self.lookupRecords(table, position + 2, result.record_count);
        try self.rules.append(self.arena, result);
    }

    /// Sets of glyph sequences at `position`, as used by multiple and alternate substitution.
    fn sequences(self: *Decoder, reader: Reader, position: usize) !void {
        const count = reader.u16Unchecked(position);
        try self.sets.ensureTotalCapacity(self.arena, @as(usize, count) + 1);
        for (0..count) |index| {
            self.sets.appendAssumeCapacity(@intCast(self.values.items.len));
            const offset = reader.u16Unchecked(position + 2 + index * 2);
            if (offset == 0) continue;
            const sequence = Reader{ .bytes = reader.bytes[offset..] };
            try self.glyphs(sequence, 2, sequence.u16Unchecked(0));
        }
        self.sets.appendAssumeCapacity(@intCast(self.values.items.len));
    }

    fn ligatureSets(self: *Decoder, reader: Reader) !void {
        const set_count = reader.u16Unchecked(4);
        try self.sets.ensureTotalCapacity(self.arena, @as(usize, set_count) + 1);
        for (0..set_count) |set_index| {
            self.sets.appendAssumeCapacity(@intCast(self.ligatures.items.len));
            const set_offset = reader.u16Unchecked(6 + set_index * 2);
            if (set_offset == 0) continue;
            const set = Reader{ .bytes = reader.bytes[set_offset..] };
            for (0..set.u16Unchecked(0)) |ligature_index| {
                const ligature_offset = set.u16Unchecked(2 + ligature_index * 2);
                if (ligature_offset == 0) {
                    try self.ligatures.append(self.arena, .{ .glyph = 0, .component_count = Ligature.absent, .components = 0 });
                    continue;
                }
                const ligature = Reader{ .bytes = set.bytes[ligature_offset..] };
                const count = ligature.u16Unchecked(2);
                try self.ligatures.append(self.arena, .{ .glyph = ligature.u16Unchecked(0), .component_count = count, .components = @intCast(self.values.items.len) });
                try self.glyphs(ligature, 4, @as(usize, count) -| 1);
            }
        }
        self.sets.appendAssumeCapacity(@intCast(self.ligatures.items.len));
    }
};

fn decodeCover(arena: std.mem.Allocator, table: Reader) !Cover {
    const format = table.u16Unchecked(0);
    const count = table.u16Unchecked(2);
    switch (format) {
        1 => {
            const glyphs = try arena.alloc(u16, count);
            for (glyphs, 0..) |*glyph, index| glyph.* = table.u16Unchecked(4 + index * 2);
            var sorted = true;
            for (glyphs[0..glyphs.len -| 1], glyphs[@min(1, glyphs.len)..]) |a, b| sorted = sorted and a < b;
            return .{ .glyphs = glyphs, .sorted = sorted };
        },
        else => {
            const ranges = try arena.alloc(CoverRange, count);
            for (ranges, 0..) |*range, index| range.* = .{
                .first = table.u16Unchecked(4 + index * 6),
                .last = table.u16Unchecked(4 + index * 6 + 2),
                .start = table.u16Unchecked(4 + index * 6 + 4),
            };
            // An empty format 2 coverage still searches ranges.
            if (ranges.len == 0) return .{ .glyphs = &.{} };
            return .{ .ranges = ranges };
        },
    }
}

pub fn decodeValue(format: u16, reader: Reader, position: usize) Value {
    var value: Value = .{};
    var cursor = position;
    inline for (.{ 0x0001, 0x0002, 0x0004, 0x0008 }, 0..) |bit, field| {
        if (format & bit != 0) {
            const raw = reader.i16At(cursor) catch 0;
            if (raw != 0) value.nonzero = true;
            switch (field) {
                0 => value.x_offset = raw,
                1 => value.y_offset = raw,
                2 => value.x_advance = raw,
                else => {},
            }
            cursor += 2;
        }
    }
    return value;
}

fn decode(arena: std.mem.Allocator, subtable: Subtable) !Data {
    var decoder: Decoder = .{ .arena = arena };
    const cover = try decodeCover(arena, subtable.coverage);
    const reader = subtable.reader;
    switch (subtable.kind) {
        .none => {},
        .single_subst => switch (subtable.format) {
            1 => {
                var result = decoder.data(cover);
                result.delta = reader.u16Unchecked(4);
                return result;
            },
            else => try decoder.glyphs(reader, 6, reader.u16Unchecked(4)),
        },
        .multiple_subst, .alternate_subst => try decoder.sequences(reader, 4),
        .ligature_subst => try decoder.ligatureSets(reader),
        .reverse_chain_subst => {
            const substitutes = 4 + 2 + @as(usize, subtable.backtrack_count) * 2 + 2 + @as(usize, subtable.lookahead_count) * 2;
            try decoder.glyphs(reader, substitutes + 2, reader.u16Unchecked(substitutes));
        },
        .context, .chain_context => {
            const chained = subtable.kind == .chain_context;
            switch (subtable.format) {
                1 => try decoder.ruleSets(reader, 4, chained),
                2 => try decoder.ruleSets(reader, if (chained) 10 else 6, chained),
                else => {
                    if (!chained) {
                        try decoder.lookupRecords(reader, 6 + @as(usize, subtable.input_count) * 2, reader.u16Unchecked(4));
                    } else {
                        const position = 4 + @as(usize, subtable.backtrack_count) * 2 + 2 + @as(usize, subtable.input_count) * 2 + 2 + @as(usize, subtable.lookahead_count) * 2;
                        try decoder.lookupRecords(reader, position + 2, reader.u16Unchecked(position));
                    }
                },
            }
        },
        .single_pos => {
            const format = reader.u16Unchecked(4);
            const size = valueRecordSize(format);
            var result = decoder.data(cover);
            switch (subtable.format) {
                1 => result.single = try arena.dupe(Value, &.{decodeValue(format, reader, 6)}),
                else => {
                    const values = try arena.alloc(Value, reader.u16Unchecked(6));
                    for (values, 0..) |*value, index| value.* = decodeValue(format, reader, 8 + index * size);
                    result.single = values;
                },
            }
            return result;
        },
        .pair_pos => {
            const format1 = reader.u16Unchecked(4);
            const format2 = reader.u16Unchecked(6);
            const len1 = valueRecordSize(format1);
            const len2 = valueRecordSize(format2);
            var result = decoder.data(cover);
            result.has_first = len1 != 0;
            result.has_second = len2 != 0;
            switch (subtable.format) {
                1 => {
                    const set_count = reader.u16Unchecked(8);
                    var sets = try arena.alloc(u32, @as(usize, set_count) + 1);
                    var pairs: std.ArrayList(Pair) = .empty;
                    const record_size = 2 + len1 + len2;
                    for (0..set_count) |set_index| {
                        sets[set_index] = @intCast(pairs.items.len);
                        const set_offset = reader.u16Unchecked(10 + set_index * 2);
                        if (set_offset == 0) continue;
                        const set = Reader{ .bytes = reader.bytes[set_offset..] };
                        const count = set.u16Unchecked(0);
                        try pairs.ensureUnusedCapacity(arena, count);
                        for (0..count) |pair| {
                            const record = 2 + pair * record_size;
                            pairs.appendAssumeCapacity(.{
                                .second = set.u16Unchecked(record),
                                .first_value = decodeValue(format1, set, record + 2),
                                .second_value = decodeValue(format2, set, record + 2 + len1),
                            });
                        }
                    }
                    sets[set_count] = @intCast(pairs.items.len);
                    result.sets = sets;
                    result.pairs = pairs.items;
                },
                else => {
                    result.class1_count = reader.u16Unchecked(12);
                    result.class2_count = reader.u16Unchecked(14);
                    const matrix = try arena.alloc([2]Value, @as(usize, result.class1_count) * result.class2_count);
                    for (matrix, 0..) |*cell, index| {
                        const record = 16 + index * (len1 + len2);
                        cell.* = .{ decodeValue(format1, reader, record), decodeValue(format2, reader, record + len1) };
                    }
                    result.matrix = matrix;
                },
            }
            return result;
        },
        .cursive_pos, .mark_base_pos, .mark_ligature_pos, .mark_mark_pos => {},
    }
    return decoder.data(cover);
}

pub fn scriptCount(self: *const Layout) u16 {
    return self.script_list.u16At(0) catch 0;
}

pub fn scriptTag(self: *const Layout, index: u16) u32 {
    return self.script_list.u32At(2 + @as(usize, index) * 6) catch 0;
}

fn recordSearch(list: Reader, tag: u32) ?u16 {
    const count = list.u16At(0) catch return null;
    var low: i32 = 0;
    var high: i32 = @as(i32, count) - 1;
    while (low <= high) {
        const mid: u16 = @intCast(@divTrunc(low + high, 2));
        const value = list.u32At(2 + @as(usize, mid) * 6) catch return null;
        if (tag < value) {
            high = @as(i32, mid) - 1;
        } else if (tag > value) {
            low = @as(i32, mid) + 1;
        } else {
            return mid;
        }
    }
    return null;
}

fn recordTarget(list: Reader, index: u16) ?Reader {
    const offset = list.u16At(2 + @as(usize, index) * 6 + 4) catch return null;
    if (offset == 0) return null;
    return list.sub(offset) catch null;
}

pub fn findScript(self: *const Layout, tag: u32) ?u16 {
    return recordSearch(self.script_list, tag);
}

pub fn findLanguage(self: *const Layout, script: u16, tag: u32) ?u16 {
    const reader = recordTarget(self.script_list, script) orelse return null;
    const languages = reader.sub(2) catch return null;
    return recordSearch(languages, tag);
}

/// LangSys of `language` in `script`, or the script's default language system.
pub fn langSys(self: *const Layout, script: u16, language: u16) ?Reader {
    if (script == no_index) return null;
    const reader = recordTarget(self.script_list, script) orelse return null;
    if (language == no_index) {
        const offset = reader.u16At(0) catch return null;
        if (offset == 0) return null;
        return reader.sub(offset) catch null;
    }
    const languages = reader.sub(2) catch return null;
    return recordTarget(languages, language);
}

pub fn requiredFeature(lang_sys: ?Reader) u16 {
    const reader = lang_sys orelse return no_index;
    return reader.u16At(2) catch no_index;
}

pub fn langSysFeatureCount(lang_sys: ?Reader) u16 {
    const reader = lang_sys orelse return 0;
    const count = reader.u16At(4) catch return 0;
    if (!reader.has(6, @as(usize, count) * 2)) return 0;
    return count;
}

pub fn langSysFeature(lang_sys: ?Reader, index: u16) u16 {
    return lang_sys.?.u16At(6 + @as(usize, index) * 2) catch no_index;
}

pub fn featureCount(self: *const Layout) u16 {
    return self.feature_list.u16At(0) catch 0;
}

pub fn featureTag(self: *const Layout, index: u16) u32 {
    if (index >= self.featureCount()) return 0;
    return self.feature_list.u32At(2 + @as(usize, index) * 6) catch 0;
}

/// Lookup indices of feature `index`, honoring FeatureVariations matched at the default instance.
pub fn featureLookups(self: *const Layout, index: u16, variations: ?u32) []const u8 {
    const feature = self.substitutedFeature(index, variations) orelse (recordTarget(self.feature_list, index) orelse return &.{});
    const count = feature.u16At(2) catch return &.{};
    const indices = feature.subLen(4, @as(usize, count) * 2) catch return &.{};
    return indices.bytes;
}

fn substitutedFeature(self: *const Layout, index: u16, variations: ?u32) ?Reader {
    const record_index = variations orelse return null;
    const table = self.feature_variations orelse return null;
    const record = 8 + @as(usize, record_index) * 8;
    const substitution_offset = table.u32At(record + 4) catch return null;
    if (substitution_offset == 0) return null;
    const substitution = table.sub(substitution_offset) catch return null;
    const count = substitution.u16At(4) catch return null;
    var low: i32 = 0;
    var high: i32 = @as(i32, count) - 1;
    while (low <= high) {
        const mid: usize = @intCast(@divTrunc(low + high, 2));
        const feature_index = substitution.u16At(6 + mid * 6) catch return null;
        if (index < feature_index) {
            high = @as(i32, @intCast(mid)) - 1;
        } else if (index > feature_index) {
            low = @as(i32, @intCast(mid)) + 1;
        } else {
            const feature_offset = substitution.u32At(6 + mid * 6 + 2) catch return null;
            return substitution.sub(feature_offset) catch null;
        }
    }
    return null;
}

/// First FeatureVariations record whose conditions hold at the default instance.
pub fn defaultVariations(self: *const Layout) ?u32 {
    const table = self.feature_variations orelse return null;
    const count = table.u32At(4) catch return null;
    for (0..count) |index| {
        const record = 8 + index * 8;
        const condition_set_offset = table.u32At(record) catch return null;
        if (conditionSetHolds(table, condition_set_offset)) return @intCast(index);
    }
    return null;
}

fn conditionSetHolds(table: Reader, offset: u32) bool {
    if (offset == 0) return true;
    const set = table.sub(offset) catch return false;
    const count = set.u16At(0) catch return false;
    for (0..count) |index| {
        const condition_offset = set.u32At(2 + index * 4) catch return false;
        const condition = set.sub(condition_offset) catch return false;
        const format = condition.u16At(0) catch return false;
        if (format != 1) return false;
        const minimum = condition.i16At(4) catch return false;
        const maximum = condition.i16At(6) catch return false;
        if (minimum > 0 or maximum < 0) return false;
    }
    return true;
}
