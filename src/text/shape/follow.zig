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

/// Follow rows of one table by lookup index, shared by every plan of a face. A row depends
/// only on its lookup and the class, not on the plan's script or features.
pub const Rows = struct {
    table_index: usize,
    /// Per lookup index and class: `any`, or a set index, with `marks` set when failure marks.
    /// Null until a plan uses the lookup.
    rows: []?[]u32,
    /// Class bitsets, `set_words` each. Set 0 is empty.
    sets: std.ArrayList(u64) = .empty,
    dedupe: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    current: []u64,
    set_words: u32,

    fn init(gpa: std.mem.Allocator, program: *const FontProgram, table_index: usize, layout: *const Layout) !Rows {
        const rows = try gpa.alloc(?[]u32, layout.lookups.len);
        errdefer gpa.free(rows);
        @memset(rows, null);
        const words = program.partition.set_words;
        const current = try gpa.alloc(u64, words);
        errdefer gpa.free(current);
        @memset(current, 0);
        var self: Rows = .{ .table_index = table_index, .rows = rows, .current = current, .set_words = words };
        errdefer self.sets.deinit(gpa);
        errdefer self.dedupe.deinit(gpa);
        _ = try self.intern(gpa);
        return self;
    }

    fn deinit(self: *Rows, gpa: std.mem.Allocator) void {
        for (self.rows) |row| {
            if (row) |entries| {
                gpa.free(entries);
            }
        }
        gpa.free(self.rows);
        gpa.free(self.current);
        self.sets.deinit(gpa);
        self.dedupe.deinit(gpa);
    }

    pub fn entry(self: *const Rows, lookup_index: u16, class: u16) u32 {
        return self.rows[lookup_index].?[class];
    }

    pub fn allows(self: *const Rows, value: u32, class: u16) bool {
        const set = self.sets.items[@as(usize, value & set_mask) * self.set_words ..][0..self.set_words];
        return set[class / 64] >> @intCast(class % 64) & 1 != 0;
    }

    fn intern(self: *Rows, gpa: std.mem.Allocator) !u32 {
        const words = self.set_words;
        const hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(self.current));
        if (self.dedupe.get(hash)) |index| {
            if (std.mem.eql(u64, self.sets.items[index * words ..][0..words], self.current)) {
                return index;
            }
        }
        const index: u32 = @intCast(self.sets.items.len / words);
        try self.sets.appendSlice(gpa, self.current);
        try self.dedupe.put(gpa, hash, index);
        return index;
    }

    /// Builds the row of `lookup_index` unless present. `start_set` holds the classes that can
    /// start the lookup, the only ones the scheduler asks about.
    pub fn ensure(self: *Rows, gpa: std.mem.Allocator, program: *const FontProgram, lookup_index: u16, start_set: []const u64) !void {
        if (self.rows[lookup_index] != null) {
            return;
        }
        const layout = switch (self.table_index) {
            0 => &program.gsub,
            else => &program.gpos,
        };
        const partition = &program.partition;
        const row = try gpa.alloc(u32, partition.class_count);
        errdefer gpa.free(row);
        @memset(row, any);
        const lookup = &layout.lookups[lookup_index];
        var builder: Builder = .{ .program = program, .current = self.current };
        for (start_set, 0..) |start_word, word_index| {
            var remaining = start_word;
            while (remaining != 0) : (remaining &= remaining - 1) {
                const class: u16 = @intCast(word_index * 64 + @ctz(remaining));
                @memset(builder.current, 0);
                builder.any = false;
                builder.marks = false;
                for (lookup.subtables) |*item| {
                    if (!partition.contains(item.coverage_id, class)) {
                        continue;
                    }
                    builder.subtable(self.table_index, item, class);
                    if (builder.any) {
                        break;
                    }
                }
                if (builder.any) {
                    continue;
                }
                var value = try self.intern(gpa);
                if (builder.marks) {
                    value |= marks;
                }
                row[class] = value;
            }
        }
        self.rows[lookup_index] = row;
    }
};

/// The follow rows of a face's GSUB and GPOS.
pub const Store = struct {
    tables: [2]Rows,

    pub fn init(gpa: std.mem.Allocator, program: *const FontProgram) !Store {
        var gsub = try Rows.init(gpa, program, 0, &program.gsub);
        errdefer gsub.deinit(gpa);
        const gpos = try Rows.init(gpa, program, 1, &program.gpos);
        return .{ .tables = .{ gsub, gpos } };
    }

    pub fn deinit(self: *Store, gpa: std.mem.Allocator) void {
        for (&self.tables) |*rows| rows.deinit(gpa);
    }
};

const Builder = struct {
    program: *const FontProgram,
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
            if (partition.value(id, @intCast(class)) == value) {
                self.addClass(@intCast(class));
            }
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
                        if (index == std.math.maxInt(u32)) {
                            continue;
                        }
                        for (data.ruleRange(index)) |r| self.rule(data, r, chained, .glyph, .{ Partition.none, Partition.none, Partition.none });
                    },
                    2 => {
                        var defs: [3]Partition.Id = .{ Partition.none, item.predicates[0], Partition.none };
                        if (chained) {
                            defs = .{ item.predicates[0], item.predicates[1], item.predicates[2] };
                        }
                        for (data.ruleRange(partition.value(defs[1], class))) |r| self.rule(data, r, chained, .class, defs);
                    },
                    else => {
                        const ids = item.predicates;
                        if (item.input_count >= 2) {
                            self.addSet(ids[item.backtrack_count + 1]);
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
                if (index == std.math.maxInt(u32)) {
                    continue;
                }
                for (data.ligatureRange(index)) |ligature| {
                    const count = ligature.component_count;
                    if (count == Layout.Ligature.absent or count == 0) {
                        continue;
                    }
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
                    if (index == std.math.maxInt(u32)) {
                        continue;
                    }
                    self.marks = true;
                    if (index + 1 >= data.sets.len) {
                        continue;
                    }
                    for (data.pairs[data.sets[index]..data.sets[index + 1]]) |pair| self.addGlyph(pair.second);
                }
            },
            else => self.any = true,
        }
    }
};
