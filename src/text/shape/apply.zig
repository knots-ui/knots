//! Lookup application, ported from hb-ot-layout-gsubgpos.hh and the GSUB/GPOS
//! subtable apply functions. Indices follow HarfBuzz: input indices are mapped
//! with `Buffer.inPos`, backtrack indices are physical.

const std = @import("std");
const Buffer = @import("Buffer.zig");
const Plan = @import("Plan.zig");
const props = @import("props.zig");
const FontProgram = @import("../font/FontProgram.zig");
const Layout = @import("../font/Layout.zig");
const Partition = @import("../font/Partition.zig");
const Reader = @import("../font/Reader.zig");
const coverage = @import("../font/coverage.zig");
const class_def = @import("../font/class_def.zig");
const gpos = @import("gpos.zig");
const follow = @import("follow.zig");

pub const max_nesting_level = 64;
pub const max_context_length = 64;

comptime {
    std.debug.assert(max_nesting_level == 64);
    std.debug.assert(max_context_length == 64);
}

pub const Table = enum(u1) { gsub, gpos };

pub const Error = error{ OutOfMemory, BufferTooLong };

pub const Context = struct {
    buffer: *Buffer,
    program: *const FontProgram,
    table: Table,
    layout: *const Layout,
    lookup_mask: u32 = 1,
    lookup_index: u16 = 0,
    lookup_props: u32 = 0,
    nesting_level_left: u32 = max_nesting_level,
    has_glyph_classes: bool,
    auto_zwnj: bool = true,
    auto_zwj: bool = true,
    random: bool = false,
    match_positions: *[max_context_length + 1]u32,
    iter_input: Iterator = undefined,
    iter_context: Iterator = undefined,
    last_base: i32 = -1,
    last_base_until: u32 = 0,
    /// No glyph in the buffer can be skipped under the current lookup flags, so matching walks adjacent glyphs.
    no_skip: bool = false,
    /// Scheduling for the table being applied: see `Plan.class_lookups`.
    class_lookups: []const u64 = &.{},
    sparse_lookups: []const u64 = &.{},
    lookup_words: u32 = 0,
    lookup_count: u32 = 0,
    dense: bool = false,
    follow: ?*const follow.Table = null,
    ordinal: u32 = 0,

    pub fn init(buffer: *Buffer, program: *const FontProgram, table: Table, positions: *[max_context_length + 1]u32) Context {
        const layout = switch (table) {
            .gsub => &program.gsub,
            .gpos => &program.gpos,
        };
        const context: Context = .{
            .buffer = buffer,
            .program = program,
            .table = table,
            .layout = layout,
            .has_glyph_classes = program.gdef.has_glyph_classes,
            .match_positions = positions,
        };
        return context;
    }

    pub fn initIters(self: *Context) void {
        self.iter_input = Iterator.init(self, false);
        self.iter_context = Iterator.init(self, true);
    }

    pub fn setLookupMask(self: *Context, mask: u32) void {
        self.lookup_mask = mask;
        self.last_base = -1;
        self.last_base_until = 0;
    }

    pub fn setLookupProps(self: *Context, lookup_props: u32) void {
        var sanitized = lookup_props;
        if (sanitized & Layout.flag_use_mark_filtering_set != 0 and (sanitized >> 16) >= self.program.gdef.mark_sets.len) {
            sanitized &= ~@as(u32, Layout.flag_use_mark_filtering_set);
        }
        self.lookup_props = sanitized;
        self.no_skip = self.canSkipNothing(sanitized);
        self.initIters();
    }

    fn canSkipNothing(self: *const Context, lookup_props: u32) bool {
        const buffer = self.buffer;
        if (buffer.scratch.has_default_ignorables) return false;
        const present = buffer.glyph_props_union;
        if (present & lookup_props & Layout.flag_ignore_flags != 0) return false;
        const mark_rules = Layout.flag_use_mark_filtering_set | Layout.flag_mark_attachment_type;
        if (present & props.glyph_mark != 0 and lookup_props & mark_rules != 0) return false;
        return true;
    }

    /// Records that the glyph at physical `position` now has `class`, for lookup scheduling.
    fn noteClass(self: *Context, position: u32, class: u16) void {
        const words = self.lookup_words;
        if (words == 0) return;
        const buffer = self.buffer;
        const bits = self.class_lookups[@as(usize, class) * words ..][0..words];
        for (buffer.active.items, bits) |*active, bit| active.* |= bit;
        if (buffer.candidates_epoch != buffer.epoch or position / 64 >= buffer.candidate_words) return;
        markCandidates(buffer, self.sparse_lookups[@as(usize, class) * words ..][0..words], position);
    }

    fn noteGlyphProps(self: *Context, glyph_props: u16) void {
        const buffer = self.buffer;
        if (buffer.glyph_props_union | glyph_props == buffer.glyph_props_union) return;
        buffer.glyph_props_union |= glyph_props;
        self.no_skip = self.canSkipNothing(self.lookup_props);
    }

    pub fn checkGlyphProperty(self: *const Context, position: u32, match_props: u32) bool {
        const s = self.buffer.slice();
        return self.checkProps(s.items(.glyph_props)[position], s.items(.class)[position], match_props);
    }

    fn checkProps(self: *const Context, glyph_props: u16, class: u16, match_props: u32) bool {
        if (glyph_props & match_props & Layout.flag_ignore_flags != 0) return false;
        if (glyph_props & props.glyph_mark != 0) return self.matchPropertiesMark(class, glyph_props, match_props);
        return true;
    }

    fn matchPropertiesMark(self: *const Context, class: u16, glyph_props: u16, match_props: u32) bool {
        if (match_props & Layout.flag_use_mark_filtering_set != 0) {
            const set = self.program.gdef.markSet(@intCast(match_props >> 16));
            if (set == Partition.none) return false;
            return self.program.partition.contains(set, class);
        }
        if (match_props & Layout.flag_mark_attachment_type != 0) {
            return match_props & Layout.flag_mark_attachment_type == glyph_props & Layout.flag_mark_attachment_type;
        }
        return true;
    }

    fn setGlyphClass(self: *Context, glyph_id: u32, class_guess: u16, ligature: bool, component: bool) void {
        const position = self.buffer.cur();
        const s = self.buffer.slice();
        var glyph_props = s.items(.glyph_props)[position];
        glyph_props |= props.glyph_substituted;
        if (ligature) {
            glyph_props |= props.glyph_ligated;
            glyph_props &= ~props.glyph_multiplied;
        }
        if (component) glyph_props |= props.glyph_multiplied;
        if (self.has_glyph_classes) {
            glyph_props = (glyph_props & props.glyph_preserve) | self.program.gdef.props(glyph_id);
        } else if (class_guess != 0) {
            glyph_props = (glyph_props & props.glyph_preserve) | class_guess;
        }
        s.items(.glyph_props)[position] = glyph_props;
        self.noteGlyphProps(glyph_props);
        const class = self.program.partition.classOf(glyph_id);
        s.items(.class)[position] = class;
        self.noteClass(position, class);
    }

    pub fn replaceGlyph(self: *Context, glyph_id: u32) Error!void {
        self.setGlyphClass(glyph_id, 0, false, false);
        try self.buffer.replaceGlyph(glyph_id);
    }

    pub fn replaceGlyphInplace(self: *Context, glyph_id: u32) void {
        self.setGlyphClass(glyph_id, 0, false, false);
        self.buffer.replaceGlyphInplace(glyph_id);
    }

    fn replaceGlyphWithLigature(self: *Context, glyph_id: u32, class_guess: u16) Error!void {
        self.setGlyphClass(glyph_id, class_guess, true, false);
        try self.buffer.replaceGlyph(glyph_id);
    }

    fn outputGlyphForComponent(self: *Context, glyph_id: u32, class_guess: u16) Error!void {
        self.setGlyphClass(glyph_id, class_guess, false, true);
        try self.buffer.outputGlyph(glyph_id);
    }

    fn randomNumber(self: *Context) u32 {
        self.buffer.random_state = @intCast(@as(u64, self.buffer.random_state) * 48271 % 2147483647);
        return self.buffer.random_state;
    }

    pub fn recurse(self: *Context, lookup_index: u16) Error!bool {
        if (self.nesting_level_left == 0) {
            self.buffer.successful = false;
            return false;
        }
        self.buffer.max_ops -= 1;
        if (self.buffer.max_ops < 0) {
            self.buffer.successful = false;
            return false;
        }
        if (lookup_index >= self.layout.lookups.len) return false;
        const lookup = &self.layout.lookups[lookup_index];
        const saved_props = self.lookup_props;
        const saved_index = self.lookup_index;
        const saved_positions = self.match_positions;
        var positions: [max_context_length + 1]u32 = undefined;
        self.match_positions = &positions;
        self.lookup_index = lookup_index;
        self.setLookupProps(lookupProps(lookup));
        self.nesting_level_left -= 1;
        const result = applySubtables(self, lookup);
        self.nesting_level_left += 1;
        self.lookup_index = saved_index;
        self.setLookupProps(saved_props);
        self.match_positions = saved_positions;
        return result;
    }

    pub fn glyphAt(self: *const Context, position: u32) u32 {
        return self.buffer.field(.id)[position];
    }

    pub fn classAt(self: *const Context, position: u32) u16 {
        return self.buffer.field(.class)[position];
    }
};

pub fn lookupProps(lookup: *const Layout.Lookup) u32 {
    return @as(u32, lookup.flags) | (@as(u32, lookup.mark_filtering_set) << 16);
}

pub const MatchData = union(enum) {
    none,
    always,
    glyphs: []const u16,
    classes: struct { values: []const u16, class_def: Partition.Id },
    coverages: []const Partition.Id,
};

const MayMatch = enum { no, yes, maybe };
const MaySkip = enum { no, yes, maybe };
pub const MatchResult = enum { match, not_match, skip };

pub const Iterator = struct {
    context: *const Context,
    idx: u32 = 0,
    end: u32 = 0,
    lookup_props: u32,
    mask: u32,
    ignore_zwnj: bool,
    ignore_zwj: bool,
    ignore_hidden: bool,
    data: MatchData = .none,
    data_index: usize = 0,

    fn init(context: *const Context, context_match: bool) Iterator {
        const mask: u32 = switch (context_match) {
            true => std.math.maxInt(u32),
            false => context.lookup_mask,
        };
        return .{
            .context = context,
            .end = context.buffer.len,
            .lookup_props = context.lookup_props,
            .ignore_zwnj = context.table == .gpos or (context_match and context.auto_zwnj),
            .ignore_zwj = context_match or context.auto_zwj,
            .ignore_hidden = context.table == .gpos,
            .mask = mask,
        };
    }

    pub fn setData(self: *Iterator, data: MatchData) void {
        self.data = data;
        self.data_index = 0;
    }

    pub fn reset(self: *Iterator, start: u32) void {
        self.idx = start;
        self.end = self.context.buffer.len;
    }

    pub fn resetBack(self: *Iterator, start: u32) void {
        self.idx = start;
    }

    pub fn resetFast(self: *Iterator, start: u32) void {
        self.idx = start;
    }

    pub fn maySkip(self: *const Iterator, position: u32) MaySkip {
        const context = self.context;
        if (!context.checkGlyphProperty(position, self.lookup_props)) return .yes;
        const s = context.buffer.slice();
        const uprops = s.items(.unicode_props)[position];
        const glyph_props = s.items(.glyph_props)[position];
        if (props.isDefaultIgnorable(uprops, glyph_props) and
            (self.ignore_zwnj or !props.isZwnj(uprops)) and
            (self.ignore_zwj or !props.isZwj(uprops)) and
            (self.ignore_hidden or !props.isHidden(uprops))) return .maybe;
        return .no;
    }

    fn mayMatch(self: *const Iterator, position: u32) MayMatch {
        const context = self.context;
        if (context.buffer.field(.mask)[position] & self.mask == 0) return .no;
        return switch (self.data) {
            .none => .maybe,
            .always => .yes,
            .glyphs => |sequence| boolMatch(context.glyphAt(position) == sequence[self.data_index]),
            .classes => |classes| boolMatch(context.program.partition.value(classes.class_def, context.classAt(position)) == classes.values[self.data_index]),
            .coverages => |ids| boolMatch(context.program.partition.contains(ids[self.data_index], context.classAt(position))),
        };
    }

    pub fn matchAt(self: *const Iterator, position: u32) MatchResult {
        return self.match(position);
    }

    fn match(self: *const Iterator, position: u32) MatchResult {
        const skip = self.maySkip(position);
        if (skip == .yes) return .skip;
        const matched = self.mayMatch(position);
        if (matched == .yes or (matched == .maybe and skip == .no)) return .match;
        if (skip == .no) return .not_match;
        return .skip;
    }

    pub fn next(self: *Iterator, unsafe_to: ?*u32) bool {
        const buffer = self.context.buffer;
        if (self.context.no_skip) {
            // Nothing can be skipped, so the next glyph either matches or ends the match.
            if (self.idx + 1 >= self.end) {
                if (unsafe_to) |target| target.* = self.end;
                return false;
            }
            self.idx += 1;
            if (self.mayMatch(buffer.inPos(self.idx)) == .no) {
                if (unsafe_to) |target| target.* = self.idx + 1;
                return false;
            }
            self.data_index += 1;
            return true;
        }
        const stop: i64 = @as(i64, self.end) - 1;
        while (@as(i64, self.idx) < stop) {
            self.idx += 1;
            switch (self.match(buffer.inPos(self.idx))) {
                .match => {
                    self.data_index += 1;
                    return true;
                },
                .not_match => {
                    if (unsafe_to) |target| target.* = self.idx + 1;
                    return false;
                },
                .skip => continue,
            }
        }
        if (unsafe_to) |target| target.* = self.end;
        return false;
    }

    pub fn prev(self: *Iterator, unsafe_from: ?*u32) bool {
        if (self.context.no_skip) {
            if (self.idx == 0) {
                if (unsafe_from) |target| target.* = 0;
                return false;
            }
            self.idx -= 1;
            if (self.mayMatch(self.idx) == .no) {
                if (unsafe_from) |target| target.* = @max(1, self.idx) - 1;
                return false;
            }
            self.data_index += 1;
            return true;
        }
        while (self.idx > 0) {
            self.idx -= 1;
            switch (self.match(self.idx)) {
                .match => {
                    self.data_index += 1;
                    return true;
                },
                .not_match => {
                    if (unsafe_from) |target| target.* = @max(1, self.idx) - 1;
                    return false;
                },
                .skip => continue,
            }
        }
        if (unsafe_from) |target| target.* = 0;
        return false;
    }
};

fn boolMatch(value: bool) MayMatch {
    return switch (value) {
        true => .yes,
        false => .no,
    };
}

fn matchInput(c: *Context, count: u32, data: MatchData, end_position: *u32, total_components: ?*u32) bool {
    const buffer = c.buffer;
    const s = buffer.slice();
    const lig_props = s.items(.lig_props);
    const glyph_props = s.items(.glyph_props);
    if (count == 1) {
        end_position.* = buffer.idx + 1;
        c.match_positions[0] = buffer.idx;
        if (total_components) |target| target.* = props.ligNumComps(lig_props[buffer.cur()], glyph_props[buffer.cur()]);
        return true;
    }
    if (count > max_context_length) return false;

    var iter = &c.iter_input;
    iter.reset(buffer.idx);
    iter.setData(data);

    var total: u32 = 0;
    const first = buffer.cur();
    const first_lig_id = props.ligId(lig_props[first]);
    const first_lig_comp = props.ligComp(lig_props[first]);
    const LigBase = enum { not_checked, may_not_skip, may_skip };
    var ligbase: LigBase = .not_checked;

    var i: u32 = 1;
    while (i < count) : (i += 1) {
        var unsafe_to: u32 = 0;
        if (!iter.next(&unsafe_to)) {
            end_position.* = unsafe_to;
            return false;
        }
        c.match_positions[i] = iter.idx;
        const position = buffer.inPos(iter.idx);
        const this_lig_id = props.ligId(lig_props[position]);
        const this_lig_comp = props.ligComp(lig_props[position]);
        if (first_lig_id != 0 and first_lig_comp != 0) {
            if (first_lig_id != this_lig_id or first_lig_comp != this_lig_comp) {
                if (ligbase == .not_checked) {
                    var found = false;
                    var j = buffer.out_len;
                    while (j > 0 and props.ligId(lig_props[j - 1]) == first_lig_id) {
                        if (props.ligComp(lig_props[j - 1]) == 0) {
                            j -= 1;
                            found = true;
                            break;
                        }
                        j -= 1;
                    }
                    if (found and iter.maySkip(j) == .yes) {
                        ligbase = .may_skip;
                    } else {
                        ligbase = .may_not_skip;
                    }
                }
                if (ligbase == .may_not_skip) return false;
            }
        } else {
            if (this_lig_id != 0 and this_lig_comp != 0 and this_lig_id != first_lig_id) return false;
        }
        total += props.ligNumCompsInLigation(lig_props[position], glyph_props[position]);
    }
    end_position.* = iter.idx + 1;
    if (total_components) |target| {
        total += props.ligNumComps(lig_props[first], glyph_props[first]);
        target.* = total;
    }
    c.match_positions[0] = buffer.idx;
    return true;
}

fn ligateInput(c: *Context, count: u32, match_end: u32, lig_glyph: u32, total_components: u32) Error!void {
    const buffer = c.buffer;
    buffer.mergeClusters(buffer.idx, match_end);

    var is_base_ligature = props.isBaseGlyph(buffer.field(.glyph_props)[buffer.inPos(c.match_positions[0])]);
    var is_mark_ligature = props.isMark(buffer.field(.glyph_props)[buffer.inPos(c.match_positions[0])]);
    for (1..count) |i| {
        if (!props.isMark(buffer.field(.glyph_props)[buffer.inPos(c.match_positions[i])])) {
            is_base_ligature = false;
            is_mark_ligature = false;
            break;
        }
    }
    const is_ligature = !is_base_ligature and !is_mark_ligature;
    const class: u16 = switch (is_ligature) {
        true => props.glyph_ligature,
        false => 0,
    };
    const lig_id: u8 = switch (is_ligature) {
        true => allocateLigId(buffer),
        false => 0,
    };
    var last_lig_id = props.ligId(buffer.field(.lig_props)[buffer.cur()]);
    var last_num_components: u32 = props.ligNumComps(buffer.field(.lig_props)[buffer.cur()], buffer.field(.glyph_props)[buffer.cur()]);
    var components_so_far = last_num_components;

    if (is_ligature) {
        const position = buffer.cur();
        buffer.field(.lig_props)[position] = props.ligPropsForLigature(lig_id, total_components);
        const uprops = &buffer.field(.unicode_props)[position];
        if (props.generalCategory(uprops.*) == .non_spacing_mark) props.setGeneralCategory(uprops, .other_letter);
    }
    try c.replaceGlyphWithLigature(lig_glyph, class);

    for (1..count) |i| {
        while (buffer.idx < c.match_positions[i] and buffer.successful) {
            if (is_ligature) {
                const position = buffer.cur();
                var this_comp: u32 = props.ligComp(buffer.field(.lig_props)[position]);
                if (this_comp == 0) this_comp = last_num_components;
                std.debug.assert(components_so_far >= last_num_components);
                const new_comp = components_so_far - last_num_components + @min(this_comp, last_num_components);
                buffer.field(.lig_props)[position] = props.ligPropsForMark(lig_id, new_comp);
            }
            buffer.nextGlyph();
        }
        const position = buffer.cur();
        last_lig_id = props.ligId(buffer.field(.lig_props)[position]);
        last_num_components = props.ligNumCompsInLigation(buffer.field(.lig_props)[position], buffer.field(.glyph_props)[position]);
        components_so_far += last_num_components;
        buffer.skipGlyph();
    }

    if (!is_mark_ligature and last_lig_id != 0) {
        var i = buffer.idx;
        while (i < buffer.len) : (i += 1) {
            const position = buffer.inPos(i);
            const lig = buffer.field(.lig_props)[position];
            if (last_lig_id != props.ligId(lig)) break;
            const this_comp: u32 = props.ligComp(lig);
            if (this_comp == 0) break;
            const new_comp = components_so_far - last_num_components + @min(this_comp, last_num_components);
            buffer.field(.lig_props)[position] = props.ligPropsForMark(lig_id, new_comp);
        }
    }
}

fn allocateLigId(buffer: *Buffer) u8 {
    while (true) {
        const lig_id: u8 = @intCast(buffer.nextSerial() & 0x07);
        if (lig_id != 0) return lig_id;
    }
}

fn matchBacktrack(c: *Context, count: u32, data: MatchData, match_start: *u32) bool {
    if (count == 0) {
        match_start.* = c.buffer.backtrackLen();
        return true;
    }
    var iter = &c.iter_context;
    iter.resetBack(c.buffer.backtrackLen());
    iter.setData(data);
    for (0..count) |_| {
        var unsafe_from: u32 = 0;
        if (!iter.prev(&unsafe_from)) {
            match_start.* = unsafe_from;
            return false;
        }
    }
    match_start.* = iter.idx;
    return true;
}

fn matchLookahead(c: *Context, count: u32, data: MatchData, start_index: u32, end_index: *u32) bool {
    if (count == 0) {
        end_index.* = start_index;
        return true;
    }
    var iter = &c.iter_context;
    std.debug.assert(start_index >= 1);
    iter.reset(start_index - 1);
    iter.setData(data);
    for (0..count) |_| {
        var unsafe_to: u32 = 0;
        if (!iter.next(&unsafe_to)) {
            end_index.* = unsafe_to;
            return false;
        }
    }
    end_index.* = iter.idx + 1;
    return true;
}

fn applyLookup(c: *Context, count_in: u32, records: []const Layout.Record, match_end: u32) Error!void {
    const buffer = c.buffer;
    var count: i64 = count_in;
    var end: i64 = undefined;
    {
        const backtrack: i64 = buffer.backtrackLen();
        end = backtrack + @as(i64, match_end) - buffer.idx;
        const delta = backtrack - @as(i64, buffer.idx);
        for (0..count_in) |j| c.match_positions[j] = @intCast(@as(i64, c.match_positions[j]) + delta);
    }

    var i: usize = 0;
    while (i < records.len and buffer.successful) : (i += 1) {
        const idx = records[i].sequence;
        if (idx >= count) continue;
        const orig_len: i64 = @as(i64, buffer.backtrackLen()) + buffer.lookaheadLen();
        if (c.match_positions[idx] >= orig_len) continue;
        if (!buffer.moveTo(c.match_positions[idx])) break;
        if (buffer.max_ops <= 0) break;

        if (!try c.recurse(records[i].lookup)) continue;

        const new_len: i64 = @as(i64, buffer.backtrackLen()) + buffer.lookaheadLen();
        var delta = new_len - orig_len;
        if (delta == 0) continue;

        end += delta;
        if (end < c.match_positions[idx]) {
            delta += @as(i64, c.match_positions[idx]) - end;
            end = c.match_positions[idx];
        }
        var next: i64 = @as(i64, idx) + 1;
        if (delta > 0) {
            if (delta + count > max_context_length) break;
        } else {
            delta = @max(delta, next - count);
            next -= delta;
        }
        const tail: usize = @intCast(count - next);
        const from: usize = @intCast(next);
        const to: usize = @intCast(next + delta);
        if (delta > 0) {
            std.mem.copyBackwards(u32, c.match_positions[to..][0..tail], c.match_positions[from..][0..tail]);
        } else {
            std.mem.copyForwards(u32, c.match_positions[to..][0..tail], c.match_positions[from..][0..tail]);
        }
        next += delta;
        count += delta;
        var j: usize = idx + 1;
        while (j < next) : (j += 1) c.match_positions[j] = c.match_positions[j - 1] + 1;
        var k: usize = @intCast(next);
        while (k < count) : (k += 1) c.match_positions[k] = @intCast(@as(i64, c.match_positions[k]) + delta);
    }
    std.debug.assert(end >= 0);
    _ = buffer.moveTo(@intCast(end));
}

fn contextApplyLookup(c: *Context, input_count: u32, data: MatchData, records: []const Layout.Record) Error!bool {
    if (input_count > max_context_length) return false;
    var match_end: u32 = 0;
    if (matchInput(c, input_count, data, &match_end, null)) {
        c.buffer.unsafeToBreak(c.buffer.idx, match_end);
        try applyLookup(c, input_count, records, match_end);
        return true;
    }
    c.buffer.unsafeToConcat(c.buffer.idx, match_end);
    return false;
}

const ChainData = struct {
    backtrack: MatchData,
    input: MatchData,
    lookahead: MatchData,
};

fn chainContextApplyLookup(c: *Context, backtrack_count: u32, input_count: u32, lookahead_count: u32, data: ChainData, records: []const Layout.Record) Error!bool {
    if (input_count > max_context_length) return false;
    const buffer = c.buffer;
    var start_index: u32 = buffer.out_len;
    var end_index: u32 = buffer.idx;
    var match_end: u32 = 0;
    const input_matched = matchInput(c, input_count, data.input, &match_end, null);
    if (input_matched) end_index = match_end;
    if (!(input_matched and matchLookahead(c, lookahead_count, data.lookahead, match_end, &end_index))) {
        buffer.unsafeToConcat(buffer.idx, end_index);
        return false;
    }
    if (!matchBacktrack(c, backtrack_count, data.backtrack, &start_index)) {
        buffer.unsafeToConcatFromOutbuffer(start_index, end_index);
        return false;
    }
    buffer.unsafeToBreakFromOutbuffer(start_index, end_index);
    try applyLookup(c, input_count, records, match_end);
    return true;
}

const RuleKind = enum { glyph, class };

const RuleContext = struct {
    chained: bool,
    kind: RuleKind,
    class_defs: [3]Partition.Id = .{ Partition.none, Partition.none, Partition.none },

    fn data(self: RuleContext, role: usize, sequence: []const u16) MatchData {
        return switch (self.kind) {
            .glyph => .{ .glyphs = sequence },
            .class => .{ .classes = .{ .values = sequence, .class_def = self.class_defs[role] } },
        };
    }

    fn matches(self: RuleContext, c: *const Context, role: usize, position: u32, value: u16) bool {
        return switch (self.kind) {
            .glyph => c.glyphAt(position) == value,
            .class => c.program.partition.value(self.class_defs[role], c.classAt(position)) == value,
        };
    }
};

fn applyRule(c: *Context, rule_context: RuleContext, data: *const Layout.Data, rule: Layout.Rule) Error!bool {
    const records = data.ruleRecords(rule);
    if (!rule_context.chained) return contextApplyLookup(c, rule.input_count, rule_context.data(1, data.input(rule)), records);
    return chainContextApplyLookup(c, rule.backtrack_count, rule.input_count, rule.lookahead_count, .{
        .backtrack = rule_context.data(0, data.backtrack(rule)),
        .input = rule_context.data(1, data.input(rule)),
        .lookahead = rule_context.data(2, data.lookahead(rule)),
    }, records);
}

fn applyRuleSet(c: *Context, rule_context: RuleContext, data: *const Layout.Data, rules: []const Layout.Rule) Error!bool {
    if (rules.len <= 4) return applyRuleSetSlow(c, rule_context, data, rules);

    const buffer = c.buffer;
    var iter = &c.iter_context;
    iter.reset(buffer.idx);
    iter.setData(.always);
    var unsafe_to: ?u32 = null;
    var unsafe_to1: u32 = 0;
    var unsafe_to2: u32 = 0;
    var first: ?u32 = null;
    var second: ?u32 = null;
    if (iter.next(&unsafe_to1)) {
        if (iter.maySkip(buffer.inPos(iter.idx)) != .no) return applyRuleSetSlow(c, rule_context, data, rules);
        first = buffer.inPos(iter.idx);
        unsafe_to1 = iter.idx + 1;
    } else {
        var unsafe_to_concat = false;
        var applied = false;
        for (rules) |rule| {
            if (!(rule.input_count <= 1 and rule.lookahead_count == 0)) {
                unsafe_to_concat = true;
                continue;
            }
            if (try applyRule(c, rule_context, data, rule)) {
                applied = true;
                break;
            }
        }
        if (unsafe_to_concat) buffer.unsafeToConcat(buffer.idx, unsafe_to1);
        return applied;
    }
    if (iter.next(null)) {
        if (iter.maySkip(buffer.inPos(iter.idx)) != .no) return applyRuleSetSlow(c, rule_context, data, rules);
        second = buffer.inPos(iter.idx);
        unsafe_to2 = iter.idx + 1;
    }

    var i: usize = 0;
    while (i < rules.len) : (i += 1) {
        const head = rules[i];
        const first_matches = switch (head.input_count > 1) {
            true => rule_context.matches(c, 1, first.?, data.input(head)[0]),
            false => switch (rule_context.chained) {
                true => head.lookahead_count == 0 or rule_context.matches(c, 2, first.?, data.lookahead(head)[0]),
                false => true,
            },
        };
        if (first_matches) {
            const len_p1 = @max(head.input_count, 1);
            const second_matches = second == null or switch (len_p1 > 2) {
                true => rule_context.matches(c, 1, second.?, data.input(head)[1]),
                false => switch (rule_context.chained) {
                    true => head.lookahead_count <= 2 - len_p1 or rule_context.matches(c, 2, second.?, data.lookahead(head)[2 - len_p1]),
                    false => true,
                },
            };
            if (second_matches) {
                if (try applyRule(c, rule_context, data, head)) {
                    if (unsafe_to) |target| buffer.unsafeToConcat(buffer.idx, target);
                    return true;
                }
            } else {
                unsafe_to = unsafe_to2;
            }
            continue;
        }
        if (unsafe_to == null) unsafe_to = unsafe_to1;
        if (head.input_count > 1) {
            while (i + 1 < rules.len) : (i += 1) {
                const next_head = rules[i + 1];
                if (next_head.input_count <= 1 or data.input(next_head)[0] != data.input(head)[0]) break;
            }
        }
    }
    if (unsafe_to) |target| buffer.unsafeToConcat(buffer.idx, target);
    return false;
}

fn applyRuleSetSlow(c: *Context, rule_context: RuleContext, data: *const Layout.Data, rules: []const Layout.Rule) Error!bool {
    for (rules) |rule| {
        if (try applyRule(c, rule_context, data, rule)) return true;
    }
    return false;
}

fn coverageIndex(c: *const Context, subtable: *const Layout.Subtable) u32 {
    if (!c.program.partition.contains(subtable.coverage_id, c.classAt(c.buffer.cur()))) return coverage.not_covered;
    return subtable.data.cover.index(c.glyphAt(c.buffer.cur()));
}

fn applyContext(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    const data = &subtable.data;
    const chained = subtable.kind == .chain_context;
    switch (subtable.format) {
        1 => {
            const index = coverageIndex(c, subtable);
            if (index == coverage.not_covered) return false;
            return applyRuleSet(c, .{ .chained = chained, .kind = .glyph }, data, data.ruleRange(index));
        },
        2 => {
            if (coverageIndex(c, subtable) == coverage.not_covered) return false;
            var rule_context: RuleContext = .{ .chained = chained, .kind = .class };
            if (chained) {
                rule_context.class_defs = .{ subtable.predicates[0], subtable.predicates[1], subtable.predicates[2] };
            } else {
                rule_context.class_defs = .{ Partition.none, subtable.predicates[0], Partition.none };
            }
            const class = c.program.partition.value(rule_context.class_defs[1], c.classAt(c.buffer.cur()));
            return applyRuleSet(c, rule_context, data, data.ruleRange(class));
        },
        3 => {
            const ids = subtable.predicates;
            if (!chained) {
                if (!c.program.partition.contains(ids[0], c.classAt(c.buffer.cur()))) return false;
                return contextApplyLookup(c, subtable.input_count, .{ .coverages = ids[1..] }, data.records);
            }
            const backtrack = subtable.backtrack_count;
            const input = subtable.input_count;
            const lookahead = subtable.lookahead_count;
            if (!c.program.partition.contains(ids[backtrack], c.classAt(c.buffer.cur()))) return false;
            return chainContextApplyLookup(c, backtrack, input, lookahead, .{
                .backtrack = .{ .coverages = ids[0..backtrack] },
                .input = .{ .coverages = ids[backtrack + 1 .. backtrack + input] },
                .lookahead = .{ .coverages = ids[backtrack + input ..][0..lookahead] },
            }, data.records);
        },
        else => return false,
    }
}

fn applySingleSubst(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    const index = coverageIndex(c, subtable);
    if (index == coverage.not_covered) return false;
    const data = &subtable.data;
    switch (subtable.format) {
        1 => {
            const glyph_id: u32 = (c.glyphAt(c.buffer.cur()) +% data.delta) & 0xFFFF;
            try c.replaceGlyph(glyph_id);
            return true;
        },
        else => {
            if (index >= data.values.len) return false;
            try c.replaceGlyph(data.values[index]);
            return true;
        },
    }
}

fn applyMultipleSubst(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    const index = coverageIndex(c, subtable);
    if (index == coverage.not_covered) return false;
    const sequence = subtable.data.sequence(index);
    const buffer = c.buffer;
    if (sequence.len == 1) {
        try c.replaceGlyph(sequence[0]);
        return true;
    }
    if (sequence.len == 0) {
        buffer.deleteGlyph();
        return true;
    }
    const position = buffer.cur();
    const class: u16 = switch (props.isLigature(buffer.field(.glyph_props)[position])) {
        true => props.glyph_base,
        false => 0,
    };
    const lig_id = props.ligId(buffer.field(.lig_props)[position]);
    for (sequence, 0..) |glyph_id, i| {
        if (lig_id == 0) buffer.field(.lig_props)[buffer.cur()] = props.ligPropsForMark(0, @intCast(i));
        try c.outputGlyphForComponent(glyph_id, class);
    }
    buffer.skipGlyph();
    return true;
}

fn applyAlternateSubst(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    const index = coverageIndex(c, subtable);
    if (index == coverage.not_covered) return false;
    const alternates = subtable.data.sequence(index);
    const count: u32 = @intCast(alternates.len);
    if (count == 0) return false;
    const glyph_mask = c.buffer.field(.mask)[c.buffer.cur()];
    const lookup_mask = c.lookup_mask;
    const shift: u5 = @intCast(@ctz(lookup_mask));
    var alt_index = (lookup_mask & glyph_mask) >> shift;
    if (alt_index == Plan.max_value and c.random) {
        c.buffer.unsafeToBreak(0, c.buffer.len);
        alt_index = c.randomNumber() % count + 1;
    }
    if (alt_index > count or alt_index == 0) return false;
    try c.replaceGlyph(alternates[alt_index - 1]);
    return true;
}

fn applyLigatureSubst(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    const index = coverageIndex(c, subtable);
    if (index == coverage.not_covered) return false;
    const data = &subtable.data;
    const ligatures = data.ligatureRange(index);
    if (ligatures.len <= 1) return applyLigatureSetSlow(c, data, ligatures);

    const buffer = c.buffer;
    var iter = &c.iter_context;
    iter.reset(buffer.idx);
    iter.setData(.always);
    var unsafe_to: u32 = 0;
    if (!iter.next(&unsafe_to)) return applyLigatureSetSlow(c, data, ligatures);
    const second = c.glyphAt(buffer.inPos(iter.idx));
    unsafe_to = iter.idx + 1;
    if (iter.maySkip(buffer.inPos(iter.idx)) != .no) return applyLigatureSetSlow(c, data, ligatures);

    var unsafe_to_concat = false;
    for (ligatures) |ligature| {
        if (ligature.component_count == Layout.Ligature.absent) continue;
        const components = ligature.component_count;
        if (components <= 1 or data.components(ligature)[0] == second) {
            if (try applyLigature(c, data, ligature)) {
                if (unsafe_to_concat) buffer.unsafeToConcat(buffer.idx, unsafe_to);
                return true;
            }
        } else if (components > 1) {
            unsafe_to_concat = true;
        }
    }
    if (unsafe_to_concat) buffer.unsafeToConcat(buffer.idx, unsafe_to);
    return false;
}

fn applyLigatureSetSlow(c: *Context, data: *const Layout.Data, ligatures: []const Layout.Ligature) Error!bool {
    for (ligatures) |ligature| {
        if (ligature.component_count == Layout.Ligature.absent) continue;
        if (try applyLigature(c, data, ligature)) return true;
    }
    return false;
}

fn applyLigature(c: *Context, data: *const Layout.Data, ligature: Layout.Ligature) Error!bool {
    const count = ligature.component_count;
    if (count == 0) return false;
    if (count == 1) {
        try c.replaceGlyph(ligature.glyph);
        return true;
    }
    if (count > max_context_length) return false;
    var match_end: u32 = 0;
    var total_components: u32 = 0;
    if (!matchInput(c, count, .{ .glyphs = data.components(ligature) }, &match_end, &total_components)) {
        c.buffer.unsafeToConcat(c.buffer.idx, match_end);
        return false;
    }
    try ligateInput(c, count, match_end, ligature.glyph, total_components);
    return true;
}

fn applyReverseChain(c: *Context, subtable: *const Layout.Subtable) bool {
    const index = coverageIndex(c, subtable);
    if (index == coverage.not_covered) return false;
    if (c.nesting_level_left != max_nesting_level) return false;
    const substitutes = subtable.data.values;
    const backtrack = subtable.backtrack_count;
    const lookahead = subtable.lookahead_count;
    if (index >= substitutes.len) return false;
    var start_index: u32 = 0;
    var end_index: u32 = 0;
    const ids = subtable.predicates;
    if (matchBacktrack(c, backtrack, .{ .coverages = ids[0..backtrack] }, &start_index) and
        matchLookahead(c, lookahead, .{ .coverages = ids[backtrack..][0..lookahead] }, c.buffer.idx + 1, &end_index))
    {
        c.buffer.unsafeToBreakFromOutbuffer(start_index, end_index);
        c.replaceGlyphInplace(substitutes[index]);
        return true;
    }
    c.buffer.unsafeToConcatFromOutbuffer(start_index, end_index);
    return false;
}

pub fn applySubtables(c: *Context, lookup: *const Layout.Lookup) Error!bool {
    for (lookup.subtables) |*subtable| {
        if (try applySubtable(c, subtable)) return true;
    }
    return false;
}

fn applySubtable(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    return switch (subtable.kind) {
        .none => false,
        .single_subst => applySingleSubst(c, subtable),
        .multiple_subst => applyMultipleSubst(c, subtable),
        .alternate_subst => applyAlternateSubst(c, subtable),
        .ligature_subst => applyLigatureSubst(c, subtable),
        .reverse_chain_subst => applyReverseChain(c, subtable),
        .context, .chain_context => applyContext(c, subtable),
        .single_pos, .pair_pos, .cursive_pos, .mark_base_pos, .mark_ligature_pos, .mark_mark_pos => gpos.apply_subtable(c, subtable),
    };
}

pub fn chainContextForGpos(c: *Context, subtable: *const Layout.Subtable) Error!bool {
    return applyContext(c, subtable);
}

fn applyForward(c: *Context, lookup_map: *const Plan.LookupMap, lookup: *const Layout.Lookup) Error!bool {
    var result = false;
    const buffer = c.buffer;
    while (buffer.successful) {
        const j = try nextStart(c, lookup_map);
        if (j > buffer.idx) buffer.nextGlyphs(j - buffer.idx);
        if (buffer.idx >= buffer.len) break;
        if (try applySubtables(c, lookup)) {
            result = true;
        } else {
            buffer.nextGlyph();
        }
    }
    return result;
}

/// Logical index of the next glyph at or after `buffer.idx` the current lookup can start at.
fn nextStart(c: *Context, lookup_map: *const Plan.LookupMap) Error!u32 {
    const buffer = c.buffer;
    if (buffer.candidates_epoch != buffer.epoch) try rebuildCandidates(c);
    const s = buffer.slice();
    const classes = s.items(.class);
    const masks = s.items(.mask);
    const glyph_props = s.items(.glyph_props);
    const offset = buffer.cur() -% buffer.idx;
    const words = buffer.candidate_words;
    const row = if (c.dense) &.{} else buffer.candidates.items[@as(usize, c.ordinal) * words ..][0..words];
    const end = buffer.len +% offset;
    const decided = if (c.no_skip) c.follow else null;
    var position = buffer.cur();
    while (position < end) {
        const word = position / 64;
        // A dense lookup visits every glyph; its start check below does the filtering.
        const all: u64 = if (c.dense) ~@as(u64, 0) else row[word];
        const bits = all & (~@as(u64, 0) << @intCast(position % 64));
        if (bits == 0) {
            position = (word + 1) * 64;
            continue;
        }
        const found: u32 = word * 64 + @ctz(bits);
        if (found >= end) break;
        position = found + 1;
        const class = classes[found];
        if (!Plan.lookupCanStart(lookup_map, class)) continue;
        if (masks[found] & c.lookup_mask == 0 or !c.checkProps(glyph_props[found], class, c.lookup_props)) continue;
        const table = decided orelse return found -% offset;
        if (found + 1 >= end) return found -% offset;
        const entry = table.entry(c.ordinal, class);
        if (entry == follow.any or table.allows(entry, classes[found + 1])) return found -% offset;
        // Every subtable would fail on the next glyph: apply the failure's only effect.
        if (entry & follow.marks != 0) {
            const logical = found -% offset;
            buffer.unsafeToConcat(logical, logical + 2);
        }
    }
    return buffer.len;
}

/// Sets `position` in the candidate mask of every lookup in `lookups`.
fn markCandidates(buffer: *Buffer, lookups: []const u64, position: u32) void {
    const words = buffer.candidate_words;
    const bit = @as(u64, 1) << @intCast(position % 64);
    const column = position / 64;
    for (lookups, 0..) |lookup_word, word_index| {
        var remaining = lookup_word;
        while (remaining != 0) : (remaining &= remaining - 1) {
            const ordinal = word_index * 64 + @ctz(remaining);
            buffer.candidates.items[ordinal * words + column] |= bit;
        }
    }
}

/// Transposes each glyph's startable lookups into per-lookup position masks.
fn rebuildCandidates(c: *Context) Error!void {
    const buffer = c.buffer;
    const lookup_words = c.lookup_words;
    const count: u32 = @intCast(buffer.glyphs.len);
    const words = (count + 63) / 64;
    try buffer.candidates.resize(buffer.allocator, @as(usize, c.lookup_count) * words);
    @memset(buffer.candidates.items, 0);
    buffer.candidate_words = words;
    for (buffer.field(.class), 0..) |class, position| {
        markCandidates(buffer, c.sparse_lookups[@as(usize, class) * lookup_words ..][0..lookup_words], @intCast(position));
    }
    buffer.candidates_epoch = buffer.epoch;
}

/// Resets scheduling for a table: which lookups the glyphs can start, and the props union.
fn resetSchedule(c: *Context) Error!void {
    const buffer = c.buffer;
    const lookup_words = c.lookup_words;
    var present: u16 = 0;
    for (buffer.field(.glyph_props)) |glyph_props| present |= glyph_props;
    buffer.glyph_props_union = present;
    try buffer.active.resize(buffer.allocator, lookup_words);
    @memset(buffer.active.items, 0);
    for (buffer.field(.class)) |class| {
        const bits = c.class_lookups[@as(usize, class) * lookup_words ..][0..lookup_words];
        for (buffer.active.items, bits) |*active, bit| active.* |= bit;
    }
    try rebuildCandidates(c);
}

/// The next lookup ordinal at or after `from` that some glyph can start.
fn nextActive(c: *const Context, from: usize, count: usize) ?u32 {
    const active = c.buffer.active.items;
    var word = from / 64;
    if (word >= active.len) return null;
    var bits = active[word] & (~@as(u64, 0) << @intCast(from % 64));
    while (true) {
        if (bits != 0) {
            const ordinal = word * 64 + @ctz(bits);
            return if (ordinal < count) @intCast(ordinal) else null;
        }
        word += 1;
        if (word >= active.len) return null;
        bits = active[word];
    }
}

fn startsHere(c: *const Context, lookup_map: *const Plan.LookupMap, position: u32) bool {
    const s = c.buffer.slice();
    if (!Plan.lookupCanStart(lookup_map, s.items(.class)[position])) return false;
    if (s.items(.mask)[position] & c.lookup_mask == 0) return false;
    return c.checkGlyphProperty(position, c.lookup_props);
}

fn applyBackward(c: *Context, lookup_map: *const Plan.LookupMap, lookup: *const Layout.Lookup) Error!bool {
    var result = false;
    const buffer = c.buffer;
    while (true) {
        if (startsHere(c, lookup_map, buffer.cur())) {
            if (try applySubtables(c, lookup)) result = true;
        }
        if (buffer.idx == 0) break;
        buffer.idx -= 1;
    }
    return result;
}

pub fn applyTable(buffer: *Buffer, program: *const FontProgram, plan: *const Plan, table: Table) !void {
    var positions: [max_context_length + 1]u32 = undefined;
    var c = Context.init(buffer, program, table, &positions);
    const lookups = plan.lookups[@backingInt(table)];
    if (lookups.len == 0 or buffer.len == 0) return;
    c.class_lookups = plan.class_lookups[@backingInt(table)];
    c.lookup_words = plan.lookup_words[@backingInt(table)];
    c.lookup_count = @intCast(lookups.len);
    c.sparse_lookups = plan.sparse_lookups[@backingInt(table)];
    c.follow = &plan.follow[@backingInt(table)];
    try resetSchedule(&c);
    c.initIters();
    var from: usize = 0;
    while (nextActive(&c, from, lookups.len)) |ordinal| : (from = ordinal + 1) {
        const lookup_map = &lookups[ordinal];
        if (buffer.len == 0 or lookup_map.mask == 0) continue;
        const lookup = &c.layout.lookups[lookup_map.index];
        c.ordinal = ordinal;
        c.dense = plan.isDense(@backingInt(table), ordinal);
        c.lookup_index = lookup_map.index;
        c.setLookupMask(lookup_map.mask);
        c.auto_zwj = lookup_map.auto_zwj;
        c.auto_zwnj = lookup_map.auto_zwnj;
        c.random = lookup_map.random;
        c.setLookupProps(lookupProps(lookup));
        switch (table) {
            .gsub => {
                if (!lookup.isReverse()) {
                    buffer.clearOutput();
                    buffer.idx = 0;
                    _ = applyForward(&c, lookup_map, lookup) catch |err| switch (err) {
                        error.BufferTooLong => {},
                        else => return err,
                    };
                    buffer.sync();
                } else {
                    buffer.idx = buffer.len - 1;
                    _ = try applyBackward(&c, lookup_map, lookup);
                }
            },
            .gpos => {
                buffer.idx = 0;
                _ = try applyForward(&c, lookup_map, lookup);
            },
        }
    }
}
