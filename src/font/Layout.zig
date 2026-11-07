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

    /// Flags in the low half, mark filtering set in the high half, as HarfBuzz packs them.
    pub fn props(self: *const Lookup) u32 {
        return @as(u32, self.flags) | (@as(u32, self.mark_filtering_set) << 16);
    }
};

pub const Subtable = struct {
    kind: Kind,
    format: u16,
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
    /// Mark positioning: the base, ligature or second mark coverage.
    cover2: Cover = .{},
    marks: []const MarkRecord = &.{},
    has_mark_array: bool = false,
    has_attach_array: bool = false,
    class_count: u16 = 0,
    /// Base or second mark records, or ligatures.
    rows: u16 = 0,
    /// Anchor slots: 0 for none, else 1 + an index into `points`. Base and second mark
    /// slots are `rows` by `class_count`; ligature slots are ranged by `sets`, components
    /// by `class_count`. Cursive subtables keep an entry and an exit slot per coverage index.
    anchors: []const u16 = &.{},
    points: []const Anchor = &.{},

    /// The anchor in `slot`, `null` for none.
    pub fn anchor(self: *const Data, slot: u16) ?Anchor {
        if (slot == 0) {
            return null;
        }
        return self.points[slot - 1];
    }

    pub fn set(self: *const Data, index: u32) []const u32 {
        if (index + 1 >= self.sets.len) {
            return &.{};
        }
        return self.sets[index..][0..2];
    }

    pub fn ruleRange(self: *const Data, index: u32) []const Rule {
        const bounds = self.set(index);
        if (bounds.len == 0) {
            return &.{};
        }
        return self.rules[bounds[0]..bounds[1]];
    }

    pub fn ligatureRange(self: *const Data, index: u32) []const Ligature {
        const bounds = self.set(index);
        if (bounds.len == 0) {
            return &.{};
        }
        return self.ligatures[bounds[0]..bounds[1]];
    }

    pub fn sequence(self: *const Data, index: u32) []const u16 {
        const bounds = self.set(index);
        if (bounds.len == 0) {
            return &.{};
        }
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
                        if (value == glyph) {
                            return @intCast(i);
                        }
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
    /// Some device table offset is set. Device tables are not applied.
    device: bool = false,
};

pub const Anchor = extern struct { x: i16 = 0, y: i16 = 0 };

pub const MarkRecord = extern struct { class: u16, x: i16, y: i16 };

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
    if (major != 1) {
        return error.OutOfBounds;
    }
    const script_list = try table.sub(try table.u16At(4));
    const feature_list = try table.sub(try table.u16At(6));
    const lookup_list = try table.sub(try table.u16At(8));
    var feature_variations: ?Reader = null;
    if (minor >= 1) {
        feature_variations = try table.offset32(10);
    }
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

    const Error = error{ OutOfMemory, OutOfBounds };

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
        if (!reader.has(6, @as(usize, count) * 2)) {
            return result;
        }
        var mark_filtering_set: u16 = no_index;
        if (flags & flag_use_mark_filtering_set != 0) {
            mark_filtering_set = reader.u16At(6 + @as(usize, count) * 2) catch return result;
        }
        result.flags = flags;
        result.mark_filtering_set = mark_filtering_set;

        const is_extension = lookup_type == extensionType(self.which);
        var effective_type = lookup_type;
        if (is_extension) {
            if (count == 0) {
                return result;
            }
            effective_type = extensionTargetType(reader, 0) orelse return result;
            for (0..count) |index| {
                if (extensionTargetType(reader, index) != effective_type) {
                    return result;
                }
            }
        }
        const kind = kindOf(self.which, effective_type) orelse return result;
        result.kind = kind;

        var subtables: std.ArrayList(Subtable) = .empty;
        for (0..count) |index| {
            const offset = reader.u16At(6 + index * 2) catch continue;
            var subtable = reader.sub(offset) catch continue;
            if (is_extension) {
                subtable = extensionTarget(subtable) orelse continue;
            }
            if (try self.compileSubtable(kind, subtable)) |compiled| {
                try subtables.append(self.arena, compiled);
            }
        }
        result.subtables = subtables.items;
        return result;
    }

    fn extensionTargetType(reader: Reader, index: usize) ?u16 {
        const offset = reader.u16At(6 + index * 2) catch return null;
        const extension = reader.sub(offset) catch return null;
        const format = extension.u16At(0) catch return null;
        if (format != 1) {
            return null;
        }
        return extension.u16At(2) catch null;
    }

    fn extensionTarget(extension: Reader) ?Reader {
        const offset = extension.u32At(4) catch return null;
        return extension.sub(offset) catch null;
    }

    /// Validates and decodes a subtable in one pass. Malformed subtables are dropped whole.
    fn compileSubtable(self: *Compiler, kind: Kind, reader: Reader) !?Subtable {
        const format = reader.u16At(0) catch return null;
        var subtable: Subtable = .{ .kind = kind, .format = format, .coverage_id = Partition.none };
        var parts: Parts = .{ .arena = self.arena };
        const result = switch (kind) {
            .none => error.OutOfBounds,
            .single_subst => self.singleSubst(&subtable, &parts, reader),
            .multiple_subst, .alternate_subst => self.sequenceSubst(&subtable, &parts, reader),
            .ligature_subst => self.ligatureSubst(&subtable, &parts, reader),
            .reverse_chain_subst => self.reverseChain(&subtable, &parts, reader),
            .single_pos => self.singlePos(&subtable, reader),
            .pair_pos => self.pairPos(&subtable, &parts, reader),
            .cursive_pos => self.cursivePos(&subtable, reader),
            .mark_base_pos, .mark_ligature_pos, .mark_mark_pos => self.markPos(&subtable, &parts, reader),
            .context, .chain_context => self.context(&subtable, &parts, reader),
        };
        result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OutOfBounds => return null,
        };
        subtable.data.sets = parts.sets.items;
        subtable.data.rules = parts.rules.items;
        subtable.data.ligatures = parts.ligatures.items;
        subtable.data.values = parts.values.items;
        subtable.data.records = parts.records.items;
        return subtable;
    }

    /// The coverage at `offset_position`, registered with the partition and decoded.
    fn coverageAt(self: *Compiler, base: Reader, offset_position: usize) Error!struct { Cover, Partition.Id } {
        const offset = try base.u16At(offset_position);
        if (offset == 0) {
            return error.OutOfBounds;
        }
        const table = try base.sub(offset);
        if (!coverage.validate(table)) {
            return error.OutOfBounds;
        }
        return .{ try decodeCover(self.arena, table), try self.builder.coverageId(table) };
    }

    fn primary(self: *Compiler, subtable: *Subtable, reader: Reader) Error!void {
        const cover, const id = try self.coverageAt(reader, 2);
        subtable.data.cover = cover;
        subtable.coverage_id = id;
    }

    fn classDefAt(self: *Compiler, base: Reader, offset_position: usize) Error!Partition.Id {
        const offset = try base.u16At(offset_position);
        if (offset == 0) {
            return self.builder.classDefId(Reader.init(&empty_class_def));
        }
        const table = try base.sub(offset);
        if (!class_def.validate(table)) {
            return error.OutOfBounds;
        }
        return self.builder.classDefId(table);
    }

    fn coverageList(self: *Compiler, reader: Reader, position: usize, count: u16, out: *std.ArrayList(Partition.Id)) Error!void {
        for (0..count) |index| {
            _, const id = try self.coverageAt(reader, position + index * 2);
            try out.append(self.arena, id);
        }
    }

    fn singleSubst(self: *Compiler, subtable: *Subtable, parts: *Parts, reader: Reader) Error!void {
        try self.primary(subtable, reader);
        switch (subtable.format) {
            1 => subtable.data.delta = try reader.u16At(4),
            2 => try parts.glyphs(reader, 6, try reader.u16At(4)),
            else => return error.OutOfBounds,
        }
    }

    fn sequenceSubst(self: *Compiler, subtable: *Subtable, parts: *Parts, reader: Reader) Error!void {
        if (subtable.format != 1) {
            return error.OutOfBounds;
        }
        try self.primary(subtable, reader);
        const count = try reader.u16At(4);
        try parts.sets.ensureTotalCapacity(self.arena, @as(usize, count) + 1);
        for (0..count) |index| {
            parts.sets.appendAssumeCapacity(@intCast(parts.values.items.len));
            const offset = try reader.u16At(6 + index * 2);
            if (offset == 0) {
                continue;
            }
            const sequence = try reader.sub(offset);
            try parts.glyphs(sequence, 2, try sequence.u16At(0));
        }
        parts.sets.appendAssumeCapacity(@intCast(parts.values.items.len));
    }

    fn ligatureSubst(self: *Compiler, subtable: *Subtable, parts: *Parts, reader: Reader) Error!void {
        if (subtable.format != 1) {
            return error.OutOfBounds;
        }
        try self.primary(subtable, reader);
        const set_count = try reader.u16At(4);
        try parts.sets.ensureTotalCapacity(self.arena, @as(usize, set_count) + 1);
        for (0..set_count) |set_index| {
            parts.sets.appendAssumeCapacity(@intCast(parts.ligatures.items.len));
            const set_offset = try reader.u16At(6 + set_index * 2);
            if (set_offset == 0) {
                continue;
            }
            const set = try reader.sub(set_offset);
            for (0..try set.u16At(0)) |ligature_index| {
                const ligature_offset = try set.u16At(2 + ligature_index * 2);
                if (ligature_offset == 0) {
                    try parts.ligatures.append(self.arena, .{ .glyph = 0, .component_count = Ligature.absent, .components = 0 });
                    continue;
                }
                const ligature = try set.sub(ligature_offset);
                const count = try ligature.u16At(2);
                try parts.ligatures.append(self.arena, .{ .glyph = try ligature.u16At(0), .component_count = count, .components = @intCast(parts.values.items.len) });
                const start = parts.values.items.len;
                try parts.glyphs(ligature, 4, @as(usize, count) -| 1);
                for (parts.values.items[start..]) |glyph| {
                    _ = try self.builder.glyphId(glyph);
                }
            }
        }
        parts.sets.appendAssumeCapacity(@intCast(parts.ligatures.items.len));
    }

    fn reverseChain(self: *Compiler, subtable: *Subtable, parts: *Parts, reader: Reader) Error!void {
        if (subtable.format != 1) {
            return error.OutOfBounds;
        }
        try self.primary(subtable, reader);
        var predicates: std.ArrayList(Partition.Id) = .empty;
        const backtrack_count = try reader.u16At(4);
        try self.coverageList(reader, 6, backtrack_count, &predicates);
        const lookahead_position = 6 + @as(usize, backtrack_count) * 2;
        const lookahead_count = try reader.u16At(lookahead_position);
        try self.coverageList(reader, lookahead_position + 2, lookahead_count, &predicates);
        const substitutes_position = lookahead_position + 2 + @as(usize, lookahead_count) * 2;
        try parts.glyphs(reader, substitutes_position + 2, try reader.u16At(substitutes_position));
        subtable.predicates = predicates.items;
        subtable.backtrack_count = backtrack_count;
        subtable.lookahead_count = lookahead_count;
    }

    fn singlePos(self: *Compiler, subtable: *Subtable, reader: Reader) Error!void {
        try self.primary(subtable, reader);
        const value_format = try reader.u16At(4);
        const size = valueRecordSize(value_format);
        switch (subtable.format) {
            1 => {
                if (!reader.has(6, size)) {
                    return error.OutOfBounds;
                }
                subtable.data.single = try self.arena.dupe(Value, &.{decodeValue(value_format, reader, 6)});
            },
            2 => {
                const count = try reader.u16At(6);
                if (!reader.has(8, @as(usize, count) * size)) {
                    return error.OutOfBounds;
                }
                const values = try self.arena.alloc(Value, count);
                for (values, 0..) |*value, index| {
                    value.* = decodeValue(value_format, reader, 8 + index * size);
                }
                subtable.data.single = values;
            },
            else => return error.OutOfBounds,
        }
    }

    fn pairPos(self: *Compiler, subtable: *Subtable, parts: *Parts, reader: Reader) Error!void {
        try self.primary(subtable, reader);
        const format1 = try reader.u16At(4);
        const format2 = try reader.u16At(6);
        const len1 = valueRecordSize(format1);
        const len2 = valueRecordSize(format2);
        const data = &subtable.data;
        data.has_first = len1 != 0;
        data.has_second = len2 != 0;
        switch (subtable.format) {
            1 => {
                const set_count = try reader.u16At(8);
                const sets = try parts.sets.addManyAsSlice(self.arena, @as(usize, set_count) + 1);
                var pairs: std.ArrayList(Pair) = .empty;
                const record_size = 2 + len1 + len2;
                for (0..set_count) |set_index| {
                    sets[set_index] = @intCast(pairs.items.len);
                    const set_offset = try reader.u16At(10 + set_index * 2);
                    if (set_offset == 0) {
                        continue;
                    }
                    const set = try reader.sub(set_offset);
                    const count = try set.u16At(0);
                    if (!set.has(2, @as(usize, count) * record_size)) {
                        return error.OutOfBounds;
                    }
                    try pairs.ensureUnusedCapacity(self.arena, count);
                    for (0..count) |pair| {
                        const record = 2 + pair * record_size;
                        const second = set.u16Unchecked(record);
                        _ = try self.builder.glyphId(second);
                        pairs.appendAssumeCapacity(.{
                            .second = second,
                            .first_value = decodeValue(format1, set, record + 2),
                            .second_value = decodeValue(format2, set, record + 2 + len1),
                        });
                    }
                }
                sets[set_count] = @intCast(pairs.items.len);
                data.pairs = pairs.items;
            },
            2 => {
                const first = try self.classDefAt(reader, 8);
                const second = try self.classDefAt(reader, 10);
                data.class1_count = try reader.u16At(12);
                data.class2_count = try reader.u16At(14);
                if (!reader.has(16, @as(usize, data.class1_count) * data.class2_count * (len1 + len2))) {
                    return error.OutOfBounds;
                }
                const matrix = try self.arena.alloc([2]Value, @as(usize, data.class1_count) * data.class2_count);
                for (matrix, 0..) |*cell, index| {
                    const record = 16 + index * (len1 + len2);
                    cell.* = .{ decodeValue(format1, reader, record), decodeValue(format2, reader, record + len1) };
                }
                data.matrix = matrix;
                subtable.predicates = try self.arena.dupe(Partition.Id, &.{ first, second });
            },
            else => return error.OutOfBounds,
        }
    }

    fn cursivePos(self: *Compiler, subtable: *Subtable, reader: Reader) Error!void {
        if (subtable.format != 1) {
            return error.OutOfBounds;
        }
        try self.primary(subtable, reader);
        const count = try reader.u16At(4);
        if (!reader.has(6, @as(usize, count) * 4)) {
            return error.OutOfBounds;
        }
        var points: Points = .{ .arena = self.arena };
        const anchors = try self.arena.alloc(u16, @as(usize, count) * 2);
        for (anchors, 0..) |*slot, index| {
            slot.* = 0;
            if (anchorAt(reader, reader.u16Unchecked(6 + index * 2))) |point| {
                slot.* = try points.slot(point);
            }
        }
        subtable.data.anchors = anchors;
        subtable.data.points = points.list.items;
    }

    fn markPos(self: *Compiler, subtable: *Subtable, parts: *Parts, reader: Reader) Error!void {
        if (subtable.format != 1) {
            return error.OutOfBounds;
        }
        try self.primary(subtable, reader);
        const cover2, const second = try self.coverageAt(reader, 4);
        const class_count = try reader.u16At(6);
        const mark_offset = try reader.u16At(8);
        const mark_array = try reader.sub(mark_offset);
        const mark_count = try mark_array.u16At(0);
        if (!mark_array.has(2, @as(usize, mark_count) * 4)) {
            return error.OutOfBounds;
        }
        const attach_offset = try reader.u16At(10);
        const attach_array = try reader.sub(attach_offset);
        const attach_count = try attach_array.u16At(0);
        const data = &subtable.data;
        data.cover2 = cover2;
        data.class_count = class_count;
        data.rows = attach_count;
        if (mark_offset != 0) {
            const marks = try self.arena.alloc(MarkRecord, mark_count);
            for (marks, 0..) |*mark, index| {
                const anchor = anchorAt(mark_array, mark_array.u16Unchecked(2 + index * 4 + 2)) orelse Anchor{};
                mark.* = .{ .class = mark_array.u16Unchecked(2 + index * 4), .x = anchor.x, .y = anchor.y };
            }
            data.marks = marks;
            data.has_mark_array = true;
        }
        var anchors: std.ArrayList(u16) = .empty;
        var points: Points = .{ .arena = self.arena };
        switch (subtable.kind) {
            .mark_ligature_pos => {
                if (!attach_array.has(2, @as(usize, attach_count) * 2)) {
                    return error.OutOfBounds;
                }
                try parts.sets.ensureTotalCapacity(self.arena, @as(usize, attach_count) + 1);
                for (0..attach_count) |index| {
                    parts.sets.appendAssumeCapacity(@intCast(anchors.items.len));
                    const offset = attach_array.u16Unchecked(2 + index * 2);
                    const attach = try attach_array.sub(offset);
                    const components = try attach.u16At(0);
                    if (!attach.has(2, @as(usize, components) * class_count * 2)) {
                        return error.OutOfBounds;
                    }
                    if (offset == 0 or attach_offset == 0) {
                        continue;
                    }
                    try points.append(&anchors, attach, @as(usize, components) * class_count);
                }
                parts.sets.appendAssumeCapacity(@intCast(anchors.items.len));
            },
            else => {
                if (!attach_array.has(2, @as(usize, attach_count) * class_count * 2)) {
                    return error.OutOfBounds;
                }
                if (attach_offset != 0) {
                    try points.append(&anchors, attach_array, @as(usize, attach_count) * class_count);
                }
            },
        }
        data.has_attach_array = attach_offset != 0;
        data.anchors = anchors.items;
        data.points = points.list.items;
        subtable.predicates = try self.arena.dupe(Partition.Id, &.{second});
    }

    fn context(self: *Compiler, subtable: *Subtable, parts: *Parts, reader: Reader) Error!void {
        const chained = subtable.kind == .chain_context;
        switch (subtable.format) {
            1 => {
                try self.primary(subtable, reader);
                try self.ruleSets(parts, reader, 4, chained, true);
            },
            2 => {
                try self.primary(subtable, reader);
                if (chained) {
                    const backtrack = try self.classDefAt(reader, 4);
                    const input = try self.classDefAt(reader, 6);
                    const lookahead = try self.classDefAt(reader, 8);
                    try self.ruleSets(parts, reader, 10, true, false);
                    subtable.predicates = try self.arena.dupe(Partition.Id, &.{ backtrack, input, lookahead });
                } else {
                    const classes = try self.classDefAt(reader, 4);
                    try self.ruleSets(parts, reader, 6, false, false);
                    subtable.predicates = try self.arena.dupe(Partition.Id, &.{classes});
                }
            },
            3 => {
                var predicates: std.ArrayList(Partition.Id) = .empty;
                if (!chained) {
                    const glyph_count = try reader.u16At(2);
                    const lookup_count = try reader.u16At(4);
                    if (glyph_count == 0) {
                        return error.OutOfBounds;
                    }
                    try self.coverageList(reader, 6, glyph_count, &predicates);
                    const cover, _ = try self.coverageAt(reader, 6);
                    subtable.data.cover = cover;
                    subtable.coverage_id = predicates.items[0];
                    subtable.input_count = glyph_count;
                    try parts.lookupRecords(reader, 6 + @as(usize, glyph_count) * 2, lookup_count);
                } else {
                    const backtrack_count = try reader.u16At(2);
                    try self.coverageList(reader, 4, backtrack_count, &predicates);
                    const input_position = 4 + @as(usize, backtrack_count) * 2;
                    const input_count = try reader.u16At(input_position);
                    if (input_count == 0) {
                        return error.OutOfBounds;
                    }
                    try self.coverageList(reader, input_position + 2, input_count, &predicates);
                    const lookahead_position = input_position + 2 + @as(usize, input_count) * 2;
                    const lookahead_count = try reader.u16At(lookahead_position);
                    try self.coverageList(reader, lookahead_position + 2, lookahead_count, &predicates);
                    const records_position = lookahead_position + 2 + @as(usize, lookahead_count) * 2;
                    const cover, _ = try self.coverageAt(reader, input_position + 2);
                    subtable.data.cover = cover;
                    subtable.coverage_id = predicates.items[backtrack_count];
                    subtable.backtrack_count = backtrack_count;
                    subtable.input_count = input_count;
                    subtable.lookahead_count = lookahead_count;
                    try parts.lookupRecords(reader, records_position + 2, try reader.u16At(records_position));
                }
                subtable.predicates = predicates.items;
            },
            else => return error.OutOfBounds,
        }
    }

    /// Rule sets at `position`: a count, then offsets to sets of offsets to rules.
    fn ruleSets(self: *Compiler, parts: *Parts, reader: Reader, position: usize, chained: bool, name_glyphs: bool) Error!void {
        const set_count = try reader.u16At(position);
        try parts.sets.ensureTotalCapacity(self.arena, @as(usize, set_count) + 1);
        for (0..set_count) |set_index| {
            parts.sets.appendAssumeCapacity(@intCast(parts.rules.items.len));
            const set_offset = try reader.u16At(position + 2 + set_index * 2);
            if (set_offset == 0) {
                continue;
            }
            const set = try reader.sub(set_offset);
            for (0..try set.u16At(0)) |rule_index| {
                const rule_offset = try set.u16At(2 + rule_index * 2);
                if (rule_offset == 0) {
                    try parts.rules.append(self.arena, .empty);
                    continue;
                }
                const start = parts.values.items.len;
                try parts.rule(try set.sub(rule_offset), chained);
                if (name_glyphs) {
                    for (parts.values.items[start..]) |glyph| {
                        _ = try self.builder.glyphId(glyph);
                    }
                }
            }
        }
        parts.sets.appendAssumeCapacity(@intCast(parts.rules.items.len));
    }
};

const empty_class_def = [_]u8{ 0, 2, 0, 0 };

/// A subtable's distinct anchor points, so large anchor matrices store two bytes per entry.
const Points = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(Anchor) = .empty,
    index: std.AutoHashMapUnmanaged(u32, u16) = .empty,

    fn slot(self: *Points, point: Anchor) Compiler.Error!u16 {
        const key = @as(u32, @as(u16, @bitCast(point.x))) << 16 | @as(u16, @bitCast(point.y));
        const entry = try self.index.getOrPut(self.arena, key);
        if (!entry.found_existing) {
            if (self.list.items.len >= std.math.maxInt(u16) - 1) {
                return error.OutOfBounds;
            }
            try self.list.append(self.arena, point);
            entry.value_ptr.* = @intCast(self.list.items.len);
        }
        return entry.value_ptr.*;
    }

    /// Slots of `count` anchor offsets after a count field. A null offset is no anchor; any
    /// other offset is an anchor, at the origin when its table is malformed.
    fn append(self: *Points, slots: *std.ArrayList(u16), table: Reader, count: usize) Compiler.Error!void {
        try slots.ensureUnusedCapacity(self.arena, count);
        for (0..count) |index| {
            const offset = table.u16Unchecked(2 + index * 2);
            if (offset == 0) {
                slots.appendAssumeCapacity(0);
                continue;
            }
            const point = anchorAt(table, offset) orelse Anchor{};
            slots.appendAssumeCapacity(try self.slot(point));
        }
    }
};

/// The arrays a subtable's `Data` points into, filled while compiling it.
const Parts = struct {
    arena: std.mem.Allocator,
    sets: std.ArrayList(u32) = .empty,
    rules: std.ArrayList(Rule) = .empty,
    ligatures: std.ArrayList(Ligature) = .empty,
    values: std.ArrayList(u16) = .empty,
    records: std.ArrayList(Record) = .empty,

    fn glyphs(self: *Parts, reader: Reader, position: usize, count: usize) Compiler.Error!void {
        if (!reader.has(position, count * 2)) {
            return error.OutOfBounds;
        }
        try self.values.ensureUnusedCapacity(self.arena, count);
        for (0..count) |index| {
            self.values.appendAssumeCapacity(reader.u16Unchecked(position + index * 2));
        }
    }

    fn lookupRecords(self: *Parts, reader: Reader, position: usize, count: usize) Compiler.Error!void {
        if (!reader.has(position, count * 4)) {
            return error.OutOfBounds;
        }
        try self.records.ensureUnusedCapacity(self.arena, count);
        for (0..count) |index| {
            self.records.appendAssumeCapacity(.{
                .sequence = reader.u16Unchecked(position + index * 4),
                .lookup = reader.u16Unchecked(position + index * 4 + 2),
            });
        }
    }

    fn rule(self: *Parts, table: Reader, chained: bool) Compiler.Error!void {
        var result: Rule = .{ .start = @intCast(self.values.items.len), .records = @intCast(self.records.items.len), .backtrack_count = 0, .input_count = 0, .lookahead_count = 0, .record_count = 0 };
        if (!chained) {
            result.input_count = try table.u16At(0);
            result.record_count = try table.u16At(2);
            const input_len = @as(usize, result.input_count) -| 1;
            try self.glyphs(table, 4, input_len);
            try self.lookupRecords(table, 4 + input_len * 2, result.record_count);
            try self.rules.append(self.arena, result);
            return;
        }
        result.backtrack_count = try table.u16At(0);
        try self.glyphs(table, 2, result.backtrack_count);
        var position: usize = 2 + @as(usize, result.backtrack_count) * 2;
        result.input_count = try table.u16At(position);
        const input_len = @as(usize, result.input_count) -| 1;
        try self.glyphs(table, position + 2, input_len);
        position += 2 + input_len * 2;
        result.lookahead_count = try table.u16At(position);
        try self.glyphs(table, position + 2, result.lookahead_count);
        position += 2 + @as(usize, result.lookahead_count) * 2;
        result.record_count = try table.u16At(position);
        try self.lookupRecords(table, position + 2, result.record_count);
        try self.rules.append(self.arena, result);
    }
};

/// An anchor point. Formats 2 and 3 are read as format 1, and other formats as the origin.
fn anchorAt(base: Reader, offset: u16) ?Anchor {
    if (offset == 0) {
        return null;
    }
    const anchor = base.sub(offset) catch return null;
    if (!anchor.has(0, 6)) {
        return null;
    }
    const format = anchor.u16Unchecked(0);
    if (format < 1 or format > 3) {
        return .{};
    }
    return .{ .x = @bitCast(anchor.u16Unchecked(2)), .y = @bitCast(anchor.u16Unchecked(4)) };
}

fn decodeCover(arena: std.mem.Allocator, table: Reader) !Cover {
    const format = table.u16Unchecked(0);
    const count = table.u16Unchecked(2);
    switch (format) {
        1 => {
            const glyphs = try arena.alloc(u16, count);
            for (glyphs, 0..) |*glyph, index| {
                glyph.* = table.u16Unchecked(4 + index * 2);
            }
            var sorted = true;
            for (glyphs[0..glyphs.len -| 1], glyphs[@min(1, glyphs.len)..]) |a, b| {
                sorted = sorted and a < b;
            }
            return .{ .glyphs = glyphs, .sorted = sorted };
        },
        else => {
            const ranges = try arena.alloc(CoverRange, count);
            for (ranges, 0..) |*range, index| {
                range.* = .{
                    .first = table.u16Unchecked(4 + index * 6),
                    .last = table.u16Unchecked(4 + index * 6 + 2),
                    .start = table.u16Unchecked(4 + index * 6 + 4),
                };
            }
            // An empty format 2 coverage still searches ranges.
            if (ranges.len == 0) {
                return .{ .glyphs = &.{} };
            }
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
            if (raw != 0) {
                value.nonzero = true;
            }
            switch (field) {
                0 => value.x_offset = raw,
                1 => value.y_offset = raw,
                2 => value.x_advance = raw,
                else => {},
            }
            cursor += 2;
        }
    }
    inline for (.{ 0x0010, 0x0020, 0x0040, 0x0080 }) |bit| {
        if (format & bit != 0) {
            if ((reader.u16At(cursor) catch 0) != 0) {
                value.device = true;
            }
            cursor += 2;
        }
    }
    return value;
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
    if (offset == 0) {
        return null;
    }
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
    if (script == no_index) {
        return null;
    }
    const reader = recordTarget(self.script_list, script) orelse return null;
    if (language == no_index) {
        const offset = reader.u16At(0) catch return null;
        if (offset == 0) {
            return null;
        }
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
    if (!reader.has(6, @as(usize, count) * 2)) {
        return 0;
    }
    return count;
}

pub fn langSysFeature(lang_sys: ?Reader, index: u16) u16 {
    return lang_sys.?.u16At(6 + @as(usize, index) * 2) catch no_index;
}

pub fn featureCount(self: *const Layout) u16 {
    return self.feature_list.u16At(0) catch 0;
}

pub fn featureTag(self: *const Layout, index: u16) u32 {
    if (index >= self.featureCount()) {
        return 0;
    }
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
    if (substitution_offset == 0) {
        return null;
    }
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
        if (conditionSetHolds(table, condition_set_offset)) {
            return @intCast(index);
        }
    }
    return null;
}

fn conditionSetHolds(table: Reader, offset: u32) bool {
    if (offset == 0) {
        return true;
    }
    const set = table.sub(offset) catch return false;
    const count = set.u16At(0) catch return false;
    for (0..count) |index| {
        const condition_offset = set.u32At(2 + index * 4) catch return false;
        const condition = set.sub(condition_offset) catch return false;
        const format = condition.u16At(0) catch return false;
        if (format != 1) {
            return false;
        }
        const minimum = condition.i16At(4) catch return false;
        const maximum = condition.i16At(6) catch return false;
        if (minimum > 0 or maximum < 0) {
            return false;
        }
    }
    return true;
}
