//! Glyph equivalence classes: glyphs that every match predicate treats the same.
//! Sets (coverages, mark sets, named glyphs) compile to bitsets over classes and
//! functions (ClassDefs) compile to class -> value arrays.

const std = @import("std");
const Reader = @import("Reader.zig");
const coverage = @import("coverage.zig");
const class_def = @import("class_def.zig");

class_of: []const u16,
class_count: u32,
outside_class: u16,
set_words: u32,
sets: []const u64,
function_values: []const u16,
predicates: []const Predicate,
/// Glyphs of each class: class `c` owns `members[member_start[c]..member_start[c + 1]]`.
member_start: []const u32 = &.{},
members: []const u16 = &.{},

const Partition = @This();

pub const Id = u32;
pub const none: Id = std.math.maxInt(Id);

pub const Predicate = struct {
    kind: Kind,
    source: Source,
    slot: u32 = 0,

    pub const Kind = enum { set, function };
    pub const Source = union(enum) {
        coverage: Reader,
        class_def: Reader,
        glyph: u32,
    };
};

pub fn classOf(self: *const Partition, glyph: u32) u16 {
    if (glyph >= self.class_of.len) return self.outside_class;
    return self.class_of[glyph];
}

pub fn contains(self: *const Partition, id: Id, class: u16) bool {
    const predicate = self.predicates[id];
    std.debug.assert(predicate.kind == .set);
    const word = self.sets[predicate.slot * self.set_words + class / 64];
    return word >> @intCast(class % 64) & 1 != 0;
}

pub fn value(self: *const Partition, id: Id, class: u16) u16 {
    const predicate = self.predicates[id];
    std.debug.assert(predicate.kind == .function);
    return self.function_values[predicate.slot * self.class_count + class];
}

pub fn membersOf(self: *const Partition, class: u16) []const u16 {
    if (class + 1 >= self.member_start.len) return &.{};
    return self.members[self.member_start[class]..self.member_start[class + 1]];
}

pub fn setBits(self: *const Partition, id: Id) []const u64 {
    const predicate = self.predicates[id];
    std.debug.assert(predicate.kind == .set);
    return self.sets[predicate.slot * self.set_words ..][0..self.set_words];
}

pub fn memoryBytes(self: *const Partition) usize {
    return self.class_of.len * 2 + self.sets.len * 8 + self.function_values.len * 2 + self.predicates.len * @sizeOf(Predicate);
}

pub const Builder = struct {
    arena: std.mem.Allocator,
    predicates: std.ArrayList(Predicate) = .empty,
    by_address: std.AutoHashMapUnmanaged(usize, Id) = .empty,
    by_glyph: std.AutoHashMapUnmanaged(u32, Id) = .empty,

    pub fn coverageId(self: *Builder, table: Reader) !Id {
        return self.tableId(.set, .{ .coverage = table });
    }

    pub fn classDefId(self: *Builder, table: Reader) !Id {
        return self.tableId(.function, .{ .class_def = table });
    }

    fn tableId(self: *Builder, kind: Predicate.Kind, source: Predicate.Source) !Id {
        const reader = switch (source) {
            .coverage, .class_def => |table| table,
            .glyph => unreachable,
        };
        const address = @intFromPtr(reader.bytes.ptr) *% 2 +% @intFromBool(kind == .function);
        const entry = try self.by_address.getOrPut(self.arena, address);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = @intCast(self.predicates.items.len);
        try self.predicates.append(self.arena, .{ .kind = kind, .source = source });
        return entry.value_ptr.*;
    }

    pub fn glyphId(self: *Builder, glyph: u32) !Id {
        const entry = try self.by_glyph.getOrPut(self.arena, glyph);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = @intCast(self.predicates.items.len);
        try self.predicates.append(self.arena, .{ .kind = .set, .source = .{ .glyph = glyph } });
        return entry.value_ptr.*;
    }

    pub fn finish(self: *Builder, scratch: std.mem.Allocator, glyph_count: u32) !Partition {
        return refine(self.arena, scratch, self.predicates.items, glyph_count);
    }
};

const glyph_domain_max = 1 << 16;

const Refiner = struct {
    scratch: std.mem.Allocator,
    class_of: []u32,
    split: std.ArrayList(u32),
    split_generation: std.ArrayList(u32),
    seen: []u32,
    generation: u32 = 0,
    next_class: u32 = 1,
    out_of_memory: bool = false,

    fn begin(self: *Refiner) void {
        self.generation += 1;
    }

    fn move(self: *Refiner, glyph: u32) !void {
        if (glyph >= self.class_of.len) return;
        if (self.seen[glyph] == self.generation) return;
        self.seen[glyph] = self.generation;
        const old = self.class_of[glyph];
        while (self.split.items.len <= old) {
            try self.split.append(self.scratch, 0);
            try self.split_generation.append(self.scratch, 0);
        }
        if (self.split_generation.items[old] != self.generation) {
            self.split_generation.items[old] = self.generation;
            self.split.items[old] = self.next_class;
            self.next_class += 1;
        }
        self.class_of[glyph] = self.split.items[old];
    }
};

fn visitMove(refiner: *Refiner, glyph: u32) void {
    refiner.move(glyph) catch {
        refiner.out_of_memory = true;
    };
}

fn domainOf(predicates: []const Predicate, glyph_count: u32) u32 {
    var domain: u32 = glyph_count;
    for (predicates) |predicate| {
        switch (predicate.source) {
            .glyph => |glyph| domain = @max(domain, glyph + 1),
            .coverage => |table| coverage.forEach(table, &domain, struct {
                fn visit(target: *u32, glyph: u32) void {
                    target.* = @max(target.*, glyph + 1);
                }
            }.visit),
            .class_def => |table| class_def.forEach(table, glyph_domain_max, &domain, struct {
                fn visit(target: *u32, glyph: u32, _: u16) void {
                    target.* = @max(target.*, glyph + 1);
                }
            }.visit) catch {},
        }
    }
    return @min(domain, glyph_domain_max);
}

fn isSortedCoverage(table: Reader) bool {
    const format = table.u16At(0) catch return false;
    const count = table.u16At(2) catch return false;
    var previous: i64 = -1;
    for (0..count) |i| {
        switch (format) {
            1 => {
                const glyph = table.u16At(4 + i * 2) catch return false;
                if (glyph <= previous) return false;
                previous = glyph;
            },
            2 => {
                const first = table.u16At(4 + i * 6) catch return false;
                const last = table.u16At(4 + i * 6 + 2) catch return false;
                if (first <= previous or last < first) return false;
                previous = last;
            },
            else => return false,
        }
    }
    return true;
}

fn isSortedClassDef(table: Reader) bool {
    const format = table.u16At(0) catch return false;
    if (format == 1) return true;
    const count = table.u16At(2) catch return false;
    var previous: i64 = -1;
    for (0..count) |i| {
        const first = table.u16At(4 + i * 6) catch return false;
        const last = table.u16At(4 + i * 6 + 2) catch return false;
        if (first <= previous or last < first) return false;
        previous = last;
    }
    return true;
}

/// Visits the glyphs a coverage matches, with binary-search semantics for unsorted tables.
fn forEachCovered(table: Reader, domain: u32, context: anytype, comptime visit: fn (@TypeOf(context), u32) void) void {
    if (isSortedCoverage(table)) return coverage.forEach(table, context, visit);
    for (0..domain) |glyph| {
        if (coverage.contains(table, @intCast(glyph))) visit(context, @intCast(glyph));
    }
}

const Classed = struct { value: u16, glyph: u32 };

const ClassedCollector = struct {
    scratch: std.mem.Allocator,
    list: *std.ArrayList(Classed),
    out_of_memory: *bool,
    fn visit(self: *const ClassedCollector, glyph: u32, class: u16) void {
        self.list.append(self.scratch, .{ .value = class, .glyph = glyph }) catch {
            self.out_of_memory.* = true;
        };
    }
};

fn classedLessThan(_: void, a: Classed, b: Classed) bool {
    if (a.value != b.value) return a.value < b.value;
    return a.glyph < b.glyph;
}

/// Calls `visit(context, glyph, value)` for each glyph with a nonzero value, with binary-search semantics for unsorted tables.
fn forEachClassed(table: Reader, domain: u32, context: anytype, comptime visit: fn (@TypeOf(context), u32, u16) void) void {
    if (isSortedClassDef(table)) {
        class_def.forEach(table, domain, context, visit) catch {};
        return;
    }
    for (0..domain) |glyph| {
        const class = class_def.value(table, @intCast(glyph));
        if (class != 0) visit(context, @intCast(glyph), class);
    }
}

fn refine(arena: std.mem.Allocator, scratch: std.mem.Allocator, predicates_in: []Predicate, glyph_count: u32) !Partition {
    const domain = domainOf(predicates_in, glyph_count);
    var refiner: Refiner = .{
        .scratch = scratch,
        .class_of = try scratch.alloc(u32, domain + 1),
        .split = .empty,
        .split_generation = .empty,
        .seen = try scratch.alloc(u32, domain + 1),
    };
    defer {
        scratch.free(refiner.class_of);
        scratch.free(refiner.seen);
        refiner.split.deinit(scratch);
        refiner.split_generation.deinit(scratch);
    }
    @memset(refiner.class_of, 0);
    @memset(refiner.seen, 0);

    var classed: std.ArrayList(Classed) = .empty;
    defer classed.deinit(scratch);
    for (predicates_in) |predicate| {
        switch (predicate.source) {
            .glyph => |glyph| {
                refiner.begin();
                try refiner.move(glyph);
            },
            .coverage => |table| {
                refiner.begin();
                forEachCovered(table, domain, &refiner, visitMove);
            },
            .class_def => |table| {
                classed.clearRetainingCapacity();
                const collector: ClassedCollector = .{ .scratch = scratch, .list = &classed, .out_of_memory = &refiner.out_of_memory };
                forEachClassed(table, domain, &collector, ClassedCollector.visit);
                std.mem.sort(Classed, classed.items, {}, classedLessThan);
                var previous: ?u16 = null;
                for (classed.items) |entry| {
                    if (previous != entry.value) refiner.begin();
                    previous = entry.value;
                    try refiner.move(entry.glyph);
                }
            },
        }
        if (refiner.out_of_memory) return error.OutOfMemory;
    }

    const compact = try scratch.alloc(u32, refiner.next_class);
    defer scratch.free(compact);
    @memset(compact, std.math.maxInt(u32));
    var class_count: u32 = 0;
    const class_of = try arena.alloc(u16, domain);
    for (refiner.class_of, 0..) |class, glyph| {
        if (compact[class] == std.math.maxInt(u32)) {
            compact[class] = class_count;
            class_count += 1;
        }
        if (glyph < domain) class_of[glyph] = @intCast(compact[class]);
    }
    const outside: u16 = @intCast(compact[refiner.class_of[domain]]);

    const set_words = (class_count + 63) / 64;
    var set_count: u32 = 0;
    var function_count: u32 = 0;
    for (predicates_in) |*predicate| {
        switch (predicate.kind) {
            .set => {
                predicate.slot = set_count;
                set_count += 1;
            },
            .function => {
                predicate.slot = function_count;
                function_count += 1;
            },
        }
    }
    const sets = try arena.alloc(u64, @as(usize, set_count) * set_words);
    @memset(sets, 0);
    const function_values = try arena.alloc(u16, @as(usize, function_count) * class_count);
    @memset(function_values, 0);

    for (predicates_in) |predicate| {
        switch (predicate.source) {
            .glyph => |glyph| {
                if (glyph < domain) setBit(sets[predicate.slot * set_words ..][0..set_words], class_of[glyph]);
            },
            .coverage => |table| {
                const fill: SetFill = .{ .bits = sets[predicate.slot * set_words ..][0..set_words], .class_of = class_of };
                forEachCovered(table, domain, &fill, SetFill.visit);
            },
            .class_def => |table| {
                const fill: ValueFill = .{ .values = function_values[predicate.slot * class_count ..][0..class_count], .class_of = class_of };
                forEachClassed(table, domain, &fill, ValueFill.visit);
            },
        }
    }

    const member_start = try arena.alloc(u32, class_count + 1);
    @memset(member_start, 0);
    for (class_of) |class| member_start[class + 1] += 1;
    for (1..member_start.len) |index| member_start[index] += member_start[index - 1];
    const members = try arena.alloc(u16, class_of.len);
    const cursor = try scratch.alloc(u32, class_count);
    defer scratch.free(cursor);
    @memcpy(cursor, member_start[0..class_count]);
    for (class_of, 0..) |class, glyph| {
        members[cursor[class]] = @intCast(glyph);
        cursor[class] += 1;
    }

    return .{
        .member_start = member_start,
        .members = members,
        .class_of = class_of,
        .class_count = class_count,
        .outside_class = outside,
        .set_words = set_words,
        .sets = sets,
        .function_values = function_values,
        .predicates = predicates_in,
    };
}

fn setBit(bits: []u64, class: u16) void {
    bits[class / 64] |= @as(u64, 1) << @intCast(class % 64);
}

const SetFill = struct {
    bits: []u64,
    class_of: []const u16,
    fn visit(self: *const SetFill, glyph: u32) void {
        if (glyph >= self.class_of.len) return;
        setBit(self.bits, self.class_of[glyph]);
    }
};

const ValueFill = struct {
    values: []u16,
    class_of: []const u16,
    fn visit(self: *const ValueFill, glyph: u32, class: u16) void {
        if (glyph >= self.class_of.len) return;
        self.values[self.class_of[glyph]] = class;
    }
};
