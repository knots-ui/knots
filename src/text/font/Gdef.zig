const std = @import("std");
const Reader = @import("Reader.zig");
const Partition = @import("Partition.zig");
const class_def = @import("class_def.zig");
const coverage = @import("coverage.zig");

glyph_props: []const u16,
has_glyph_classes: bool,
mark_sets: []const Partition.Id,
lig_caret_list: ?Reader,

const Gdef = @This();

pub const props_base_glyph: u16 = 0x02;
pub const props_ligature: u16 = 0x04;
pub const props_mark: u16 = 0x08;
pub const props_class_mask: u16 = props_base_glyph | props_ligature | props_mark;

pub const empty = Gdef{ .glyph_props = &.{}, .has_glyph_classes = false, .mark_sets = &.{}, .lig_caret_list = null };

pub fn props(self: *const Gdef, glyph: u32) u16 {
    if (glyph >= self.glyph_props.len) return 0;
    return self.glyph_props[glyph];
}

pub fn markSet(self: *const Gdef, index: u16) Partition.Id {
    if (index >= self.mark_sets.len) return Partition.none;
    return self.mark_sets[index];
}

pub fn compile(arena: std.mem.Allocator, table: ?Reader, glyph_count: u32, builder: *Partition.Builder) error{OutOfMemory}!Gdef {
    const reader = table orelse return empty;
    return compileTable(arena, reader, glyph_count, builder) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.OutOfBounds => empty,
    };
}

fn compileTable(arena: std.mem.Allocator, table: Reader, glyph_count: u32, builder: *Partition.Builder) error{ OutOfMemory, OutOfBounds }!Gdef {
    const major = try table.u16At(0);
    const minor = try table.u16At(2);
    if (major != 1) return error.OutOfBounds;
    const glyph_classes = try validClassDef(table, 4);
    const mark_classes = try validClassDef(table, 10);
    const props_array = try arena.alloc(u16, glyph_count);
    @memset(props_array, 0);
    if (glyph_classes) |reader| {
        _ = try builder.classDefId(reader);
        if (mark_classes) |marks| _ = try builder.classDefId(marks);
        for (props_array, 0..) |*slot, glyph| {
            slot.* = switch (class_def.value(reader, @intCast(glyph))) {
                1 => props_base_glyph,
                2 => props_ligature,
                3 => props_mark | markAttach(mark_classes, glyph),
                else => 0,
            };
        }
    }
    var mark_sets: []Partition.Id = &.{};
    if (minor >= 2) mark_sets = try compileMarkSets(arena, table, builder);
    return .{
        .glyph_props = props_array,
        .has_glyph_classes = glyph_classes != null,
        .mark_sets = mark_sets,
        .lig_caret_list = try table.offset16(8),
    };
}

fn validClassDef(table: Reader, position: usize) !?Reader {
    const reader = try table.offset16(position) orelse return null;
    if (!class_def.validate(reader)) return null;
    return reader;
}

fn markAttach(classes: ?Reader, glyph: usize) u16 {
    const reader = classes orelse return 0;
    return @as(u16, @truncate(class_def.value(reader, @intCast(glyph)))) << 8;
}

fn compileMarkSets(arena: std.mem.Allocator, table: Reader, builder: *Partition.Builder) ![]Partition.Id {
    const sets = try table.offset16(12) orelse return &.{};
    const format = try sets.u16At(0);
    if (format != 1) return &.{};
    const count = try sets.u16At(2);
    const ids = try arena.alloc(Partition.Id, count);
    for (ids, 0..) |*id, index| {
        id.* = Partition.none;
        const offset = sets.u32At(4 + index * 4) catch continue;
        if (offset == 0) continue;
        const reader = sets.sub(offset) catch continue;
        if (!coverage.validate(reader)) continue;
        id.* = try builder.coverageId(reader);
    }
    return ids;
}

/// Caret offsets inside ligature `glyph` in font units, written to `out`. Returns how many there are.
pub fn ligatureCarets(self: *const Gdef, glyph: u32, out: []i16) usize {
    const list = self.lig_caret_list orelse return 0;
    const coverage_offset = list.u16At(0) catch return 0;
    const covered = list.sub(coverage_offset) catch return 0;
    if (!coverage.validate(covered)) return 0;
    const index = coverage.index(covered, glyph);
    if (index == coverage.not_covered) return 0;
    const count = list.u16At(2) catch return 0;
    if (index >= count) return 0;
    const lig_glyph = list.sub(list.u16At(4 + @as(usize, index) * 2) catch return 0) catch return 0;
    const caret_count = lig_glyph.u16At(0) catch return 0;
    const written = @min(caret_count, out.len);
    for (out[0..written], 0..) |*slot, caret| {
        slot.* = 0;
        const value = lig_glyph.sub(lig_glyph.u16At(2 + caret * 2) catch continue) catch continue;
        const format = value.u16At(0) catch continue;
        if (format == 1 or format == 3) slot.* = value.i16At(2) catch 0;
    }
    return written;
}
