//! GPOS subtables, the legacy `kern` machine and attachment propagation,
//! ported from OT/Layout/GPOS, hb-kern.hh and GPOS.hh.

const std = @import("std");
const apply = @import("apply.zig");
const Buffer = @import("Buffer.zig");
const Plan = @import("Plan.zig");
const props = @import("props.zig");
const FontProgram = @import("../font/FontProgram.zig");
const Layout = @import("../font/Layout.zig");
const Kern = @import("../font/Kern.zig");
const Reader = @import("../font/Reader.zig");
const coverage = @import("../font/coverage.zig");
const class_def = @import("../font/class_def.zig");

pub const attach_type_mark: u8 = 1;
pub const attach_type_cursive: u8 = 2;

const Context = apply.Context;
const Error = apply.Error;

pub fn apply_subtable(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    return switch (subtable.kind) {
        .single_pos => applySingle(c, subtable),
        .pair_pos => applyPair(c, subtable),
        .cursive_pos => applyCursive(c, subtable),
        .mark_base_pos => applyMarkBase(c, subtable),
        .mark_ligature_pos => applyMarkLigature(c, subtable),
        .mark_mark_pos => applyMarkMark(c, subtable),
        else => false,
    };
}

fn glyphAt(c: *const Context, index: u32) u32 {
    return c.buffer.field(.id)[index];
}

fn coverageIndex(table: Reader, glyph: u32) u32 {
    return coverage.index(table, glyph);
}

fn offsetTarget(reader: Reader, position: usize) ?Reader {
    const offset = reader.u16At(position) catch return null;
    if (offset == 0) return null;
    return reader.sub(offset) catch null;
}

const ValueTarget = struct {
    x_advance: *i32,
    x_offset: *i32,
    y_offset: *i32,
};

fn target(buffer: *Buffer, index: u32) ValueTarget {
    const s = buffer.slice();
    return .{
        .x_advance = &s.items(.x_advance)[index],
        .x_offset = &s.items(.x_offset)[index],
        .y_offset = &s.items(.y_offset)[index],
    };
}

fn addValue(value: Layout.Value, into: ValueTarget) bool {
    into.x_offset.* +|= value.x_offset;
    into.y_offset.* +|= value.y_offset;
    into.x_advance.* +|= value.x_advance;
    return value.nonzero;
}

fn applySingle(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    const buffer = c.buffer;
    if (!c.program.partition.contains(subtable.coverage_id, c.classAt(buffer.idx))) return false;
    const data = &subtable.data;
    const index = data.cover.index(glyphAt(c, buffer.idx));
    if (index == coverage.not_covered) return false;
    switch (subtable.format) {
        1 => _ = addValue(data.single[0], target(buffer, buffer.idx)),
        else => {
            if (index >= data.single.len) return false;
            _ = addValue(data.single[index], target(buffer, buffer.idx));
        },
    }
    buffer.idx += 1;
    return true;
}

fn applyPair(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    const buffer = c.buffer;
    if (!c.program.partition.contains(subtable.coverage_id, c.classAt(buffer.idx))) return false;
    const data = &subtable.data;
    const index = data.cover.index(glyphAt(c, buffer.idx));
    if (index == coverage.not_covered) return false;
    var iter = &c.iter_input;
    iter.resetFast(buffer.idx);
    iter.setData(.none);
    var unsafe_to: u32 = 0;
    if (!iter.next(&unsafe_to)) {
        buffer.unsafeToConcat(buffer.idx, unsafe_to);
        return false;
    }
    const second = iter.idx;
    switch (subtable.format) {
        1 => return applyPairSet(c, data, index, second),
        else => {
            const class1 = c.program.partition.value(subtable.predicates[0], c.classAt(buffer.idx));
            const class2 = c.program.partition.value(subtable.predicates[1], c.classAt(second));
            if (class1 >= data.class1_count or class2 >= data.class2_count) {
                buffer.unsafeToConcat(buffer.idx, second + 1);
                return false;
            }
            const cell = data.matrix[@as(usize, class1) * data.class2_count + class2];
            const applied_first = data.has_first and addValue(cell[0], target(buffer, buffer.idx));
            const applied_second = data.has_second and addValue(cell[1], target(buffer, second));
            finishPair(buffer, applied_first or applied_second, data.has_second, second);
            return true;
        },
    }
}

fn finishPair(buffer: *Buffer, applied: bool, has_second_value: bool, second_in: u32) void {
    var second = second_in;
    if (applied) {
        buffer.unsafeToBreak(buffer.idx, second + 1);
    } else {
        buffer.unsafeToConcat(buffer.idx, second + 1);
    }
    if (has_second_value) {
        second += 1;
        buffer.unsafeToBreak(buffer.idx, second + 1);
    }
    buffer.idx = second;
}

fn applyPairSet(c: *Context, data: *const Layout.Data, index: u32, second: u32) bool {
    const buffer = c.buffer;
    if (index + 1 >= data.sets.len) {
        buffer.unsafeToConcat(buffer.idx, second + 1);
        return false;
    }
    const pairs = data.pairs[data.sets[index]..data.sets[index + 1]];
    const wanted = glyphAt(c, second);
    var low: i32 = 0;
    var high: i32 = @as(i32, @intCast(pairs.len)) - 1;
    while (low <= high) {
        const mid: usize = @intCast(@divTrunc(low + high, 2));
        const pair = pairs[mid];
        if (wanted < pair.second) {
            high = @as(i32, @intCast(mid)) - 1;
        } else if (wanted > pair.second) {
            low = @as(i32, @intCast(mid)) + 1;
        } else {
            const applied_first = data.has_first and addValue(pair.first_value, target(buffer, buffer.idx));
            const applied_second = data.has_second and addValue(pair.second_value, target(buffer, second));
            finishPair(buffer, applied_first or applied_second, data.has_second, second);
            return true;
        }
    }
    buffer.unsafeToConcat(buffer.idx, second + 1);
    return false;
}

const Point = struct { x: i32, y: i32 };

fn anchorAt(base: Reader, offset: u16) ?Reader {
    if (offset == 0) return null;
    const anchor = base.sub(offset) catch return null;
    if (!anchor.has(0, 6)) return null;
    return anchor;
}

fn anchorPoint(anchor: ?Reader) Point {
    const reader = anchor orelse return .{ .x = 0, .y = 0 };
    const format = reader.u16At(0) catch return .{ .x = 0, .y = 0 };
    if (format < 1 or format > 3) return .{ .x = 0, .y = 0 };
    return .{ .x = reader.i16At(2) catch 0, .y = reader.i16At(4) catch 0 };
}

fn entryExit(subtable: *const Layout.Subtable, glyph: u32, which: usize) ?Reader {
    const reader = subtable.reader;
    const index = subtable.data.cover.index(glyph);
    const count = reader.u16At(4) catch return null;
    if (index >= count) return null;
    const offset = reader.u16At(6 + @as(usize, index) * 4 + which * 2) catch return null;
    return anchorAt(reader, offset);
}

fn applyCursive(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    const buffer = c.buffer;
    const entry = entryExit(subtable, glyphAt(c, buffer.idx), 0) orelse return false;
    var iter = &c.iter_input;
    iter.resetFast(buffer.idx);
    iter.setData(.none);
    var unsafe_from: u32 = 0;
    if (!iter.prev(&unsafe_from)) {
        buffer.unsafeToConcatFromOutbuffer(unsafe_from, buffer.idx + 1);
        return false;
    }
    const exit = entryExit(subtable, glyphAt(c, iter.idx), 1) orelse {
        buffer.unsafeToConcatFromOutbuffer(iter.idx, buffer.idx + 1);
        return false;
    };
    const i = iter.idx;
    const j = buffer.idx;
    buffer.unsafeToBreak(i, j + 1);
    const exit_point = anchorPoint(exit);
    const entry_point = anchorPoint(entry);
    const s = buffer.slice();
    const advances = s.items(.x_advance);
    const x_offsets = s.items(.x_offset);
    const y_offsets = s.items(.y_offset);
    const chains = s.items(.attach_chain);
    const types = s.items(.attach_type);

    advances[i] = exit_point.x +| x_offsets[i];
    const d = entry_point.x +| x_offsets[j];
    advances[j] -|= d;
    x_offsets[j] -|= d;

    var child = i;
    var parent = j;
    var y_offset: i32 = entry_point.y - exit_point.y;
    if (c.lookup_props & Layout.flag_right_to_left == 0) {
        child = j;
        parent = i;
        y_offset = -y_offset;
    }
    reverseCursiveMinorOffset(buffer, child, parent, 0);
    const chain = @as(i64, parent) - @as(i64, child);
    if (chain < std.math.minInt(i16) or chain > std.math.maxInt(i16)) {
        chains[child] = 0;
        buffer.idx += 1;
        return true;
    }
    chains[child] = @intCast(chain);
    types[child] = attach_type_cursive;
    buffer.scratch.has_gpos_attachment = true;
    y_offsets[child] = y_offset;
    if (chains[parent] == -chains[child]) {
        chains[parent] = 0;
        y_offsets[parent] = 0;
    }
    buffer.idx += 1;
    return true;
}

fn reverseCursiveMinorOffset(buffer: *Buffer, i: u32, new_parent: u32, nesting: u32) void {
    if (nesting > apply.max_nesting_level) return;
    const s = buffer.slice();
    const chains = s.items(.attach_chain);
    const types = s.items(.attach_type);
    const chain = chains[i];
    const kind = types[i];
    if (chain == 0 or kind & attach_type_cursive == 0) return;
    chains[i] = 0;
    const j_signed = @as(i64, i) + chain;
    if (j_signed < 0 or j_signed >= buffer.len) return;
    const j: u32 = @intCast(j_signed);
    if (j == new_parent) return;
    if (chain == std.math.minInt(i16)) return;
    const reversed: i16 = -chain;
    reverseCursiveMinorOffset(buffer, j, new_parent, nesting + 1);
    s.items(.y_offset)[j] = 0 -| s.items(.y_offset)[i];
    chains[j] = reversed;
    types[j] = kind;
}

fn resolveCrossOffset(buffer: *Buffer, glyph_pos_in: u32) i32 {
    const s = buffer.slice();
    var glyph_pos = glyph_pos_in;
    var offset = s.items(.y_offset)[glyph_pos];
    while (s.items(.attach_type)[glyph_pos] & attach_type_cursive != 0) {
        const chain = s.items(.attach_chain)[glyph_pos];
        if (chain == 0) break;
        const parent = @as(i64, glyph_pos) + chain;
        if (parent < 0 or parent >= buffer.len) break;
        glyph_pos = @intCast(parent);
        offset +|= s.items(.y_offset)[glyph_pos];
    }
    return offset;
}

/// MarkArray::apply: attach the current mark to `glyph_pos` using row `glyph_index` of `anchors`.
fn applyMarkArray(c: *Context, mark_array: Reader, mark_index: u32, glyph_index: u32, anchors: ?Reader, class_count: u16, glyph_pos: u32) bool {
    const buffer = c.buffer;
    const mark_count = mark_array.u16At(0) catch 0;
    var mark_class: u16 = 0;
    var mark_anchor_offset: u16 = 0;
    if (mark_index < mark_count) {
        mark_class = mark_array.u16At(2 + @as(usize, mark_index) * 4) catch 0;
        mark_anchor_offset = mark_array.u16At(2 + @as(usize, mark_index) * 4 + 2) catch 0;
    }
    const matrix = anchors orelse return false;
    const rows = matrix.u16At(0) catch 0;
    if (glyph_index >= rows or mark_class >= class_count) return false;
    const glyph_anchor_offset = matrix.u16At(2 + (@as(usize, glyph_index) * class_count + mark_class) * 2) catch return false;
    if (glyph_anchor_offset == 0) return false;
    const glyph_anchor = anchorAt(matrix, glyph_anchor_offset);

    buffer.unsafeToBreak(glyph_pos, buffer.idx + 1);
    const mark_point = anchorPoint(anchorAt(mark_array, mark_anchor_offset));
    const base_point = anchorPoint(glyph_anchor);
    const base_offset = resolveCrossOffset(buffer, glyph_pos);
    const s = buffer.slice();
    const mark = buffer.idx;
    const chain = @as(i64, glyph_pos) - @as(i64, mark);
    if (chain < std.math.minInt(i16) or chain > std.math.maxInt(i16)) {
        s.items(.attach_chain)[mark] = 0;
        buffer.idx += 1;
        return true;
    }
    s.items(.attach_chain)[mark] = @intCast(chain);
    s.items(.attach_type)[mark] = attach_type_mark;
    s.items(.x_offset)[mark] = base_point.x - mark_point.x;
    s.items(.y_offset)[mark] = (base_point.y - mark_point.y) +| base_offset;
    buffer.scratch.has_gpos_attachment = true;
    buffer.idx += 1;
    return true;
}

fn baseAccept(buffer: *Buffer, idx: u32) bool {
    const s = buffer.slice();
    const glyph_props = s.items(.glyph_props);
    const lig_props = s.items(.lig_props);
    const multiplied = glyph_props[idx] & props.glyph_multiplied != 0;
    if (!multiplied or props.ligComp(lig_props[idx]) == 0) return true;
    if (idx == 0) return true;
    const previous = idx - 1;
    return props.isMark(glyph_props[previous]) or
        glyph_props[previous] & props.glyph_multiplied == 0 or
        props.ligId(lig_props[idx]) != props.ligId(lig_props[previous]) or
        props.ligComp(lig_props[idx]) != props.ligComp(lig_props[previous]) + 1;
}

fn ligatureAccept(buffer: *Buffer, idx: u32) bool {
    const s = buffer.slice();
    return s.items(.glyph_props)[idx] & props.glyph_multiplied == 0 or props.ligComp(s.items(.lig_props)[idx]) == 0;
}

const AcceptFn = *const fn (*Buffer, u32) bool;

fn findBase(c: *Context, accept: AcceptFn, base_coverage: Reader) bool {
    const buffer = c.buffer;
    var iter = &c.iter_input;
    iter.lookup_props = Layout.flag_ignore_marks;
    iter.setData(.none);
    if (c.last_base_until > buffer.idx) {
        c.last_base_until = 0;
        c.last_base = -1;
    }
    var j = buffer.idx;
    while (j > c.last_base_until) : (j -= 1) {
        var result = iter.matchAt(j - 1);
        if (result == .match and !accept(buffer, j - 1) and coverageIndex(base_coverage, glyphAt(c, j - 1)) == coverage.not_covered) result = .skip;
        if (result == .match) {
            c.last_base = @intCast(j - 1);
            break;
        }
    }
    c.last_base_until = buffer.idx;
    if (c.last_base == -1) {
        buffer.unsafeToConcatFromOutbuffer(0, buffer.idx + 1);
        return false;
    }
    return true;
}

fn applyMarkBase(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    const buffer = c.buffer;
    const mark_index = subtable.data.cover.index(glyphAt(c, buffer.idx));
    if (mark_index == coverage.not_covered) return false;
    const reader = subtable.reader;
    const base_coverage = reader.sub(reader.u16At(4) catch return false) catch return false;
    if (!findBase(c, baseAccept, base_coverage)) return false;
    const idx: u32 = @intCast(c.last_base);
    const base_index = coverageIndex(base_coverage, glyphAt(c, idx));
    if (base_index == coverage.not_covered) {
        buffer.unsafeToConcatFromOutbuffer(idx, buffer.idx + 1);
        return false;
    }
    const class_count = reader.u16At(6) catch return false;
    const mark_array = offsetTarget(reader, 8) orelse return false;
    return applyMarkArray(c, mark_array, mark_index, base_index, offsetTarget(reader, 10), class_count, idx);
}

fn applyMarkLigature(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    const buffer = c.buffer;
    const mark_index = subtable.data.cover.index(glyphAt(c, buffer.idx));
    if (mark_index == coverage.not_covered) return false;
    const reader = subtable.reader;
    const ligature_coverage = reader.sub(reader.u16At(4) catch return false) catch return false;
    if (!findBase(c, ligatureAccept, ligature_coverage)) return false;
    const idx: u32 = @intCast(c.last_base);
    const lig_index = coverageIndex(ligature_coverage, glyphAt(c, idx));
    if (lig_index == coverage.not_covered) {
        buffer.unsafeToConcatFromOutbuffer(idx, buffer.idx + 1);
        return false;
    }
    var attach: ?Reader = null;
    if (offsetTarget(reader, 10)) |array| {
        const count = array.u16At(0) catch 0;
        if (lig_index < count) attach = offsetTarget(array, 2 + @as(usize, lig_index) * 2);
    }
    const comp_count: u32 = switch (attach == null) {
        true => 0,
        false => attach.?.u16At(0) catch 0,
    };
    if (comp_count == 0) {
        buffer.unsafeToConcatFromOutbuffer(idx, buffer.idx + 1);
        return false;
    }
    const lig_props = buffer.field(.lig_props);
    const lig_id = props.ligId(lig_props[idx]);
    const mark_id = props.ligId(lig_props[buffer.idx]);
    const mark_comp: u32 = props.ligComp(lig_props[buffer.idx]);
    var comp_index = comp_count - 1;
    if (lig_id != 0 and lig_id == mark_id and mark_comp > 0) comp_index = @min(comp_count, mark_comp) - 1;
    const class_count = reader.u16At(6) catch return false;
    const mark_array = offsetTarget(reader, 8) orelse return false;
    return applyMarkArray(c, mark_array, mark_index, comp_index, attach, class_count, idx);
}

fn applyMarkMark(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    const buffer = c.buffer;
    const mark1_index = subtable.data.cover.index(glyphAt(c, buffer.idx));
    if (mark1_index == coverage.not_covered) return false;
    var iter = &c.iter_input;
    iter.resetFast(buffer.idx);
    iter.setData(.none);
    iter.lookup_props = c.lookup_props & ~@as(u32, Layout.flag_ignore_flags);
    var unsafe_from: u32 = 0;
    if (!iter.prev(&unsafe_from)) {
        buffer.unsafeToConcatFromOutbuffer(unsafe_from, buffer.idx + 1);
        return false;
    }
    const j = iter.idx;
    const s = buffer.slice();
    if (!props.isMark(s.items(.glyph_props)[j])) {
        buffer.unsafeToConcatFromOutbuffer(j, buffer.idx + 1);
        return false;
    }
    const lig_props = s.items(.lig_props);
    const id1 = props.ligId(lig_props[buffer.idx]);
    const id2 = props.ligId(lig_props[j]);
    const comp1 = props.ligComp(lig_props[buffer.idx]);
    const comp2 = props.ligComp(lig_props[j]);
    const good = switch (id1 == id2) {
        true => id1 == 0 or comp1 == comp2,
        false => (id1 > 0 and comp1 == 0) or (id2 > 0 and comp2 == 0),
    };
    if (!good) {
        buffer.unsafeToConcatFromOutbuffer(j, buffer.idx + 1);
        return false;
    }
    const reader = subtable.reader;
    const mark2_coverage = reader.sub(reader.u16At(4) catch return false) catch return false;
    const mark2_index = coverageIndex(mark2_coverage, glyphAt(c, j));
    if (mark2_index == coverage.not_covered) {
        buffer.unsafeToConcatFromOutbuffer(j, buffer.idx + 1);
        return false;
    }
    const class_count = reader.u16At(6) catch return false;
    const mark_array = offsetTarget(reader, 8) orelse return false;
    return applyMarkArray(c, mark_array, mark1_index, mark2_index, offsetTarget(reader, 10), class_count, j);
}

pub fn applyKern(buffer: *Buffer, program: *const FontProgram, plan: *const Plan) void {
    const kern = &program.kern;
    buffer.unsafeToConcat(0, Buffer.all);
    var seen_cross_stream = false;
    for (kern.subtables) |subtable| {
        if (!bufferHasLeft(buffer, subtable)) continue;
        if (!seen_cross_stream and subtable.cross_stream) {
            seen_cross_stream = true;
            const s = buffer.slice();
            for (s.items(.attach_type)[0..buffer.len], s.items(.attach_chain)[0..buffer.len]) |*kind, *chain| {
                kind.* = attach_type_cursive;
                chain.* = -1;
            }
        }
        if (plan.kern_mask == 0) continue;
        kernMachine(buffer, program, plan.kern_mask, subtable);
    }
}

fn bufferHasLeft(buffer: *Buffer, subtable: Kern.Subtable) bool {
    for (buffer.field(.id)[0..buffer.len]) |glyph| {
        var low: i32 = 0;
        var high: i32 = @as(i32, subtable.count) - 1;
        while (low <= high) {
            const mid: usize = @intCast(@divTrunc(low + high, 2));
            const left: u32 = subtable.pairs.u16At(mid * 6) catch return false;
            if (glyph < left) {
                high = @as(i32, @intCast(mid)) - 1;
            } else if (glyph > left) {
                low = @as(i32, @intCast(mid)) + 1;
            } else {
                return true;
            }
        }
    }
    return false;
}

fn kernMachine(buffer: *Buffer, program: *const FontProgram, kern_mask: u32, subtable: Kern.Subtable) void {
    buffer.unsafeToConcat(0, Buffer.all);
    var positions: [apply.max_context_length + 1]u32 = undefined;
    var c = Context.init(buffer, program, .gpos, &positions);
    c.setLookupMask(kern_mask);
    c.setLookupProps(Layout.flag_ignore_marks);
    var iter = &c.iter_input;
    const count = buffer.len;
    var idx: u32 = 0;
    while (idx < count) {
        const s = buffer.slice();
        if (s.items(.mask)[idx] & kern_mask == 0) {
            idx += 1;
            continue;
        }
        iter.resetFast(idx);
        var unsafe_to: u32 = 0;
        if (!iter.next(&unsafe_to)) {
            idx = unsafe_to;
            continue;
        }
        const i = idx;
        const j = iter.idx;
        const kerning: i32 = Kern.value(subtable, s.items(.id)[i], s.items(.id)[j]);
        if (kerning != 0) {
            if (subtable.cross_stream) {
                s.items(.y_offset)[j] = kerning;
                buffer.scratch.has_gpos_attachment = true;
            } else {
                const kern1 = kerning >> 1;
                const kern2 = kerning - kern1;
                s.items(.x_advance)[i] +|= kern1;
                s.items(.x_advance)[j] +|= kern2;
                s.items(.x_offset)[j] +|= kern2;
            }
            buffer.unsafeToBreak(i, j + 1);
        }
        idx = iter.idx;
    }
}

pub fn propagateAttachmentOffsets(buffer: *Buffer) void {
    if (!buffer.scratch.has_gpos_attachment) return;
    for (0..buffer.len) |i| {
        if (buffer.field(.attach_chain)[i] != 0) propagate(buffer, @intCast(i), apply.max_nesting_level);
    }
}

fn propagate(buffer: *Buffer, i: u32, nesting: u32) void {
    const s = buffer.slice();
    const chains = s.items(.attach_chain);
    const chain = chains[i];
    const kind = s.items(.attach_type)[i];
    chains[i] = 0;
    const j_signed = @as(i64, i) + chain;
    if (j_signed < 0 or j_signed >= buffer.len) return;
    const j: u32 = @intCast(j_signed);
    if (nesting == 0) return;
    if (chains[j] != 0) propagate(buffer, j, nesting - 1);
    const x_offsets = s.items(.x_offset);
    const y_offsets = s.items(.y_offset);
    if (kind & attach_type_cursive != 0) {
        y_offsets[i] +|= y_offsets[j];
        return;
    }
    x_offsets[i] +|= x_offsets[j];
    const advances = s.items(.x_advance);
    if (j < i) {
        for (j..i) |k| x_offsets[i] -|= advances[k];
    } else {
        for (i..j) |k| x_offsets[i] +|= advances[k];
    }
}
