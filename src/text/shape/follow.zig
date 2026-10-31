//! What the glyph after a lookup's candidate decides, per lookup and start class.
//!
//! When no glyph can be skipped and the glyph after a candidate is not in the
//! lookup's follow set, every subtable fails on that glyph. The attempt's only
//! effect is then `unsafe_to_concat` over the candidate and that glyph, which the
//! scheduler applies without running the lookup.

const std = @import("std");
const FontProgram = @import("../font/FontProgram.zig");
const Layout = @import("../font/Layout.zig");
const Partition = @import("../font/Partition.zig");
const max_context_length = 64;

/// The next glyph cannot decide the attempt: run the lookup.
pub const any: u32 = std.math.maxInt(u32);
/// A failed attempt marks the candidate and the next glyph unsafe to concat.
pub const marks: u32 = 1 << 31;
pub const set_mask: u32 = marks - 1;

pub const Table = struct {
    /// Per lookup ordinal and class: `any`, or a set index, with `marks` set when failure marks.
    entries: []const u32,
    /// Class bitsets, `set_words` each. Set 0 is empty.
    sets: []const u64,
    class_count: u32,
    set_words: u32,

    pub fn entry(self: *const Table, ordinal: u32, class: u16) u32 {
        return self.entries[@as(usize, ordinal) * self.class_count + class];
    }

    pub fn allows(self: *const Table, value: u32, class: u16) bool {
        const set = self.sets[@as(usize, value & set_mask) * self.set_words ..][0..self.set_words];
        return set[class / 64] >> @intCast(class % 64) & 1 != 0;
    }
};

const Builder = struct {
    arena: std.mem.Allocator,
    program: *const FontProgram,
    words: u32,
    sets: std.ArrayList(u64) = .empty,
    dedupe: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    current: []u64,
    any: bool = false,
    marks: bool = false,

    fn classes(self: *const Builder) *const Partition {
        return &self.program.partition;
    }

    fn addClass(self: *Builder, class: u16) void {
        self.current[class / 64] |= @as(u64, 1) << @intCast(class % 64);
    }

    fn addGlyph(self: *Builder, glyph: u16) void {
        self.addClass(self.classes().classOf(glyph));
    }

    fn addSet(self: *Builder, id: Partition.Id) void {
        for (self.current, self.classes().setBits(id)) |*word, bits| word.* |= bits;
    }

    /// Classes whose value under the ClassDef `id` is `value`.
    fn addValue(self: *Builder, id: Partition.Id, value: u16) void {
        const partition = self.classes();
        for (0..partition.class_count) |class| {
            if (partition.value(id, @intCast(class)) == value) self.addClass(@intCast(class));
        }
    }

    /// One rule's demand on the next glyph.
    fn rule(self: *Builder, data: *const Layout.Data, item: Layout.Rule, chained: bool, kind: enum { glyph, class }, defs: [3]Partition.Id) void {
        if (item.input_count > max_context_length) {
            self.any = true;
            return;
        }
        if (item.input_count >= 2) {
            const value = data.input(item)[0];
            switch (kind) {
                .glyph => self.addGlyph(value),
                .class => self.addValue(defs[1], value),
            }
            self.marks = true;
            return;
        }
        if (chained and item.lookahead_count >= 1) {
            const value = data.lookahead(item)[0];
            switch (kind) {
                .glyph => self.addGlyph(value),
                .class => self.addValue(defs[2], value),
            }
            self.marks = true;
            return;
        }
        self.any = true;
    }

    fn subtable(self: *Builder, table_index: usize, item: *const Layout.Subtable, class: u16) void {
        const partition = self.classes();
        const data = &item.data;
        switch (item.kind) {
            .context, .chain_context => {
                const chained = item.kind == .chain_context;
                switch (item.format) {
                    1 => for (partition.membersOf(class)) |glyph| {
                        const index = data.cover.index(glyph);
                        if (index == std.math.maxInt(u32)) continue;
                        for (data.ruleRange(index)) |r| self.rule(data, r, chained, .glyph, .{ Partition.none, Partition.none, Partition.none });
                    },
                    2 => {
                        const defs: [3]Partition.Id = if (chained)
                            .{ item.predicates[0], item.predicates[1], item.predicates[2] }
                        else
                            .{ Partition.none, item.predicates[0], Partition.none };
                        for (data.ruleRange(partition.value(defs[1], class))) |r| self.rule(data, r, chained, .class, defs);
                    },
                    else => {
                        const ids = item.predicates;
                        if (item.input_count >= 2) {
                            self.addSet(if (chained) ids[item.backtrack_count + 1] else ids[1]);
                            self.marks = true;
                        } else if (chained and item.lookahead_count >= 1) {
                            self.addSet(ids[item.backtrack_count + item.input_count]);
                            self.marks = true;
                        } else self.any = true;
                    },
                }
            },
            .ligature_subst => for (partition.membersOf(class)) |glyph| {
                const index = data.cover.index(glyph);
                if (index == std.math.maxInt(u32)) continue;
                for (data.ligatureRange(index)) |ligature| {
                    const count = ligature.component_count;
                    if (count == Layout.Ligature.absent or count == 0) continue;
                    if (count == 1 or count > max_context_length) {
                        self.any = true;
                        continue;
                    }
                    self.addGlyph(data.components(ligature)[0]);
                    self.marks = true;
                }
            },
            .pair_pos => {
                if (table_index == 0 or item.format != 1) {
                    self.any = true;
                    return;
                }
                for (partition.membersOf(class)) |glyph| {
                    const index = data.cover.index(glyph);
                    if (index == std.math.maxInt(u32)) continue;
                    self.marks = true;
                    if (index + 1 >= data.sets.len) continue;
                    for (data.pairs[data.sets[index]..data.sets[index + 1]]) |pair| self.addGlyph(pair.second);
                }
            },
            else => self.any = true,
        }
    }

    fn intern(self: *Builder) !u32 {
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(self.current));
        if (self.dedupe.get(hash)) |index| {
            if (std.mem.eql(u64, self.sets.items[index * self.words ..][0..self.words], self.current)) return index;
        }
        const index: u32 = @intCast(self.sets.items.len / self.words);
        try self.sets.appendSlice(self.arena, self.current);
        try self.dedupe.put(self.arena, hash, index);
        return index;
    }
};

pub fn build(arena: std.mem.Allocator, program: *const FontProgram, table_index: usize, layout: *const Layout, lookups: anytype) !Table {
    const partition = &program.partition;
    const words = partition.set_words;
    var builder: Builder = .{ .arena = arena, .program = program, .words = words, .current = try arena.alloc(u64, words) };
    @memset(builder.current, 0);
    _ = try builder.intern();
    const entries = try arena.alloc(u32, lookups.len * partition.class_count);
    @memset(entries, any);
    for (lookups, 0..) |lookup_map, ordinal| {
        const lookup = &layout.lookups[lookup_map.index];
        for (lookup_map.start, 0..) |start_word, word_index| {
            var remaining = start_word;
            while (remaining != 0) : (remaining &= remaining - 1) {
                const class: u16 = @intCast(word_index * 64 + @ctz(remaining));
                if (class >= partition.class_count) break;
                @memset(builder.current, 0);
                builder.any = false;
                builder.marks = false;
                for (lookup.subtables) |*item| {
                    if (!partition.contains(item.coverage_id, class)) continue;
                    builder.subtable(table_index, item, class);
                    if (builder.any) break;
                }
                if (builder.any) continue;
                var value = try builder.intern();
                if (builder.marks) value |= marks;
                entries[ordinal * partition.class_count + class] = value;
            }
        }
    }
    return .{ .entries = entries, .sets = builder.sets.items, .class_count = partition.class_count, .set_words = words };
}
