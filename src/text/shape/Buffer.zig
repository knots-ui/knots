//! Structure-of-arrays glyph buffer with HarfBuzz's output semantics.
//! Glyphs before `out_len` are output, the rest are unconsumed input starting
//! at input index `idx`. Both live in one array, so length changes splice in place.

const std = @import("std");
const unicode = @import("../unicode/root.zig");

allocator: std.mem.Allocator,
glyphs: std.MultiArrayList(Glyph) = .empty,
/// Bumped whenever glyphs change physical position, which invalidates `candidates`.
epoch: u32 = 0,
/// Lookup scheduling, maintained by apply.zig: per lookup ordinal, a bitmask over
/// physical positions of glyphs that may start it. Bits can be stale after a
/// substitution, so a visit rechecks the class.
candidates: std.ArrayList(u64) = .empty,
candidates_epoch: u32 = std.math.maxInt(u32),
/// Words per lookup in `candidates`.
candidate_words: u32 = 0,
/// Lookup ordinals some glyph in the buffer can start, one bit each.
active: std.ArrayList(u64) = .empty,
/// Union of every glyph's GDEF props, to tell when no lookup flag can skip a glyph.
glyph_props_union: u16 = 0,
len: u32 = 0,
idx: u32 = 0,
out_len: u32 = 0,
have_output: bool = false,
serial: u32 = 0,
random_state: u32 = 1,
scratch: Scratch = .{},
max_ops: i64 = 0,
max_len: u32 = 0,
successful: bool = true,

const Buffer = @This();

pub const Glyph = struct {
    id: u32,
    cluster: u32,
    mask: u32 = 0,
    unicode_props: u16 = 0,
    glyph_props: u16 = 0,
    lig_props: u8 = 0,
    class: u16 = 0,
    normalized: u32 = 0,
    x_advance: i32 = 0,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    attach_chain: i16 = 0,
    attach_type: u8 = 0,
};

pub const Scratch = packed struct {
    has_default_ignorables: bool = false,
    has_continuations: bool = false,
    has_cgj: bool = false,
    has_space_fallback: bool = false,
    has_fraction_slash: bool = false,
    has_glyph_flags: bool = false,
    has_unsafe_to_concat: bool = false,
    has_gpos_attachment: bool = false,
    has_marks: bool = false,
};

pub const flag_unsafe_to_break: u32 = 0x1;
pub const flag_unsafe_to_concat: u32 = 0x2;
pub const flag_defined: u32 = 0x7;

pub const max_len_factor = 64;
pub const max_len_min = 16384;
pub const max_len_default = 0x3FFFFFFF;
pub const max_ops_factor = 1024;
pub const max_ops_min = 16384;
pub const max_ops_default = 0x1FFFFFFF;

comptime {
    std.debug.assert(max_len_factor == 64);
    std.debug.assert(max_ops_factor == 1024);
}

pub fn init(allocator: std.mem.Allocator) Buffer {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Buffer) void {
    self.glyphs.deinit(self.allocator);
    self.candidates.deinit(self.allocator);
    self.active.deinit(self.allocator);
}

pub fn reset(self: *Buffer) void {
    self.glyphs.clearRetainingCapacity();
    self.epoch +%= 1;
    self.len = 0;
    self.idx = 0;
    self.out_len = 0;
    self.have_output = false;
    self.serial = 0;
    self.random_state = 1;
    self.scratch = .{};
    self.successful = true;
}

fn markMoved(self: *Buffer) void {
    self.epoch +%= 1;
}

pub fn add(self: *Buffer, codepoint: u32, cluster: u32) !void {
    std.debug.assert(!self.have_output);
    try self.glyphs.append(self.allocator, .{ .id = codepoint, .cluster = cluster });
    self.markMoved();
    self.len += 1;
}

/// Appends every codepoint of `text` with its byte offset as the cluster, invalid bytes as U+FFFD.
pub fn addText(self: *Buffer, text: []const u8) !void {
    std.debug.assert(!self.have_output and self.glyphs.len == self.len);
    const base = self.glyphs.len;
    try self.glyphs.resize(self.allocator, base + text.len);
    const s = self.glyphs.slice();
    inline for (comptime std.enums.values(std.MultiArrayList(Glyph).Field)) |tag| {
        if (tag != .id and tag != .cluster) @memset(s.items(tag)[base..], std.mem.zeroes(@FieldType(Glyph, @tagName(tag))));
    }
    const ids = s.items(.id)[base..];
    const clusters = s.items(.cluster)[base..];
    const ascii = asciiPrefix(text);
    widenAscii(text[0..ascii], ids[0..ascii], clusters[0..ascii]);
    var count = ascii;
    var index = ascii;
    while (index < text.len) {
        if (text[index] < 0x80) {
            ids[count] = text[index];
            clusters[count] = @intCast(index);
            count += 1;
            index += 1;
            continue;
        }
        const decoded = unicode.decodeUtf8(text, index);
        ids[count] = decoded.codepoint;
        clusters[count] = @intCast(index);
        count += 1;
        index += decoded.len;
    }
    self.glyphs.shrinkRetainingCapacity(base + count);
    self.markMoved();
    self.len = @intCast(base + count);
}

const ascii_lanes = 16;

/// Length of the leading run of ASCII bytes, `ascii_lanes` bytes per step.
pub fn asciiPrefix(text: []const u8) usize {
    var index: usize = 0;
    while (index + ascii_lanes <= text.len) : (index += ascii_lanes) {
        const bytes: @Vector(ascii_lanes, u8) = text[index..][0..ascii_lanes].*;
        if (@reduce(.Max, bytes) >= 0x80) break;
    }
    while (index < text.len and text[index] < 0x80) index += 1;
    return index;
}

/// Codepoints and clusters of an ASCII run, widened `ascii_lanes` at a time.
fn widenAscii(text: []const u8, ids: []u32, clusters: []u32) void {
    var index: usize = 0;
    const step: @Vector(ascii_lanes, u32) = std.simd.iota(u32, ascii_lanes);
    while (index + ascii_lanes <= text.len) : (index += ascii_lanes) {
        const bytes: @Vector(ascii_lanes, u8) = text[index..][0..ascii_lanes].*;
        ids[index..][0..ascii_lanes].* = @as(@Vector(ascii_lanes, u32), bytes);
        clusters[index..][0..ascii_lanes].* = step + @as(@Vector(ascii_lanes, u32), @splat(@intCast(index)));
    }
    while (index < text.len) : (index += 1) {
        ids[index] = text[index];
        clusters[index] = @intCast(index);
    }
}

pub fn startShaping(self: *Buffer) void {
    const len: i64 = self.len;
    self.max_len = @intCast(@max(@min(len * max_len_factor, max_len_default), max_len_min));
    self.max_ops = @max(@min(len * max_ops_factor, max_ops_default), max_ops_min);
}

pub fn nextSerial(self: *Buffer) u32 {
    self.serial +%= 1;
    return self.serial;
}

pub fn slice(self: *Buffer) std.MultiArrayList(Glyph).Slice {
    return self.glyphs.slice();
}

/// Physical position of input index `i`.
pub fn inPos(self: *const Buffer, i: u32) u32 {
    if (!self.have_output) return i;
    std.debug.assert(i >= self.idx);
    return self.out_len + (i - self.idx);
}

pub fn backtrackLen(self: *const Buffer) u32 {
    if (self.have_output) return self.out_len;
    return self.idx;
}

pub fn lookaheadLen(self: *const Buffer) u32 {
    return self.len - self.idx;
}

pub fn cur(self: *const Buffer) u32 {
    return self.inPos(self.idx);
}

pub fn field(self: *Buffer, comptime name: std.MultiArrayList(Glyph).Field) []@FieldType(Glyph, @tagName(name)) {
    return self.glyphs.items(name);
}

pub fn clearOutput(self: *Buffer) void {
    std.debug.assert(self.glyphs.len == self.len);
    self.have_output = true;
    self.idx = 0;
    self.out_len = 0;
}

pub fn sync(self: *Buffer) void {
    std.debug.assert(self.have_output);
    self.out_len += self.len - self.idx;
    self.idx = self.len;
    self.len = self.out_len;
    self.have_output = false;
    self.out_len = 0;
    self.idx = 0;
    std.debug.assert(self.glyphs.len == self.len);
}

pub fn clearPositions(self: *Buffer) void {
    self.have_output = false;
    self.out_len = 0;
    const s = self.slice();
    @memset(s.items(.x_advance), 0);
    @memset(s.items(.x_offset), 0);
    @memset(s.items(.y_offset), 0);
    @memset(s.items(.attach_chain), 0);
    @memset(s.items(.attach_type), 0);
}

pub fn nextGlyph(self: *Buffer) void {
    if (self.have_output) self.out_len += 1;
    self.idx += 1;
}

pub fn nextGlyphs(self: *Buffer, n: u32) void {
    if (self.have_output) self.out_len += n;
    self.idx += n;
}

pub fn skipGlyph(self: *Buffer) void {
    if (self.have_output) {
        self.glyphs.orderedRemove(self.cur());
        self.markMoved();
    }
    self.idx += 1;
}

pub fn replaceGlyphInplace(self: *Buffer, glyph_id: u32) void {
    std.debug.assert(!self.have_output);
    self.field(.id)[self.idx] = glyph_id;
}

pub fn replaceGlyph(self: *Buffer, glyph_id: u32) !void {
    try self.replaceGlyphs(1, &.{glyph_id});
}

pub fn outputGlyph(self: *Buffer, glyph_id: u32) !void {
    try self.replaceGlyphs(0, &.{glyph_id});
}

/// Replaces `num_in` input glyphs with copies of the first one carrying the given ids.
pub fn replaceGlyphs(self: *Buffer, num_in: u32, glyph_ids: []const u32) !void {
    std.debug.assert(self.have_output);
    std.debug.assert(self.idx + num_in <= self.len);
    try self.checkGrowth(glyph_ids.len, num_in);
    self.mergeClusters(self.idx, self.idx + num_in);
    const source_pos = self.originPos();
    const origin = self.glyphs.get(source_pos);
    const position = self.cur();
    try self.splice(position, num_in, glyph_ids.len);
    for (glyph_ids, 0..) |glyph_id, offset| {
        var copy = origin;
        copy.id = glyph_id;
        self.glyphs.set(position + offset, copy);
    }
    self.idx += num_in;
    self.out_len += @intCast(glyph_ids.len);
}

fn originPos(self: *const Buffer) u32 {
    if (self.idx < self.len) return self.cur();
    std.debug.assert(self.out_len > 0);
    return self.out_len - 1;
}

pub fn dropLastOutput(self: *Buffer) void {
    std.debug.assert(self.have_output and self.out_len > 0);
    self.glyphs.orderedRemove(self.out_len - 1);
    self.markMoved();
    self.out_len -= 1;
}

pub fn outputGlyphInfo(self: *Buffer, glyph: Glyph) !void {
    std.debug.assert(self.have_output);
    try self.checkGrowth(1, 0);
    try self.glyphs.insert(self.allocator, self.cur(), glyph);
    self.markMoved();
    self.out_len += 1;
}

pub fn copyGlyph(self: *Buffer) !void {
    try self.outputGlyphInfo(self.glyphs.get(self.cur()));
}

fn checkGrowth(self: *Buffer, added: usize, removed: usize) !void {
    if (added <= removed) return;
    if (self.glyphs.len + added - removed > self.max_len) {
        self.successful = false;
        return error.BufferTooLong;
    }
}

fn splice(self: *Buffer, position: u32, remove: u32, insert: usize) !void {
    const old_len = self.glyphs.len;
    if (insert != remove) self.markMoved();
    const tail = old_len - position - remove;
    if (insert > remove) try self.glyphs.resize(self.allocator, old_len + insert - remove);
    const s = self.glyphs.slice();
    inline for (comptime std.enums.values(std.MultiArrayList(Glyph).Field)) |tag| {
        const items = s.items(tag);
        const source = items[position + remove ..][0..tail];
        const target = items[position + insert ..][0..tail];
        if (insert > remove) {
            std.mem.copyBackwards(@TypeOf(items[0]), target, source);
        } else {
            std.mem.copyForwards(@TypeOf(items[0]), target, source);
        }
    }
    if (insert < remove) self.glyphs.shrinkRetainingCapacity(old_len + insert - remove);
}

/// `i` is an output index, see HarfBuzz's `move_to`.
pub fn moveTo(self: *Buffer, i: u32) bool {
    if (!self.have_output) {
        std.debug.assert(i <= self.len);
        self.idx = i;
        return true;
    }
    if (!self.successful) return false;
    std.debug.assert(i <= self.out_len + (self.len - self.idx));
    if (self.out_len < i) {
        const count = i - self.out_len;
        self.max_ops -= count;
        if (self.max_ops < 0) {
            self.successful = false;
            return false;
        }
        self.idx += count;
        self.out_len += count;
    } else if (self.out_len > i) {
        const count = self.out_len - i;
        self.max_ops -= count;
        if (self.max_ops < 0) {
            self.successful = false;
            return false;
        }
        if (self.idx < count) {
            self.len += count - self.idx;
            self.idx = count;
        }
        self.idx -= count;
        self.out_len -= count;
    }
    return true;
}

pub fn setCluster(cluster: *u32, mask: *u32, value: u32, flags: u32) void {
    if (cluster.* != value) mask.* = (mask.* & ~flag_defined) | (flags & flag_defined);
    cluster.* = value;
}

pub fn mergeClusters(self: *Buffer, start: u32, end: u32) void {
    if (end - start < 2) return;
    self.mergeClustersImpl(start, end);
}

fn mergeClustersImpl(self: *Buffer, start_in: u32, end_in: u32) void {
    self.max_ops -= end_in - start_in;
    if (self.max_ops < 0) self.successful = false;
    var start = start_in;
    var end = end_in;
    const clusters = self.field(.cluster);
    const masks = self.field(.mask);

    var cluster = clusters[self.inPos(start)];
    for (start + 1..end) |i| cluster = @min(cluster, clusters[self.inPos(@intCast(i))]);

    if (cluster != clusters[self.inPos(end - 1)]) {
        while (end < self.len and clusters[self.inPos(end - 1)] == clusters[self.inPos(end)]) end += 1;
    }
    if (cluster != clusters[self.inPos(start)]) {
        while (self.idx < start and clusters[self.inPos(start - 1)] == clusters[self.inPos(start)]) start -= 1;
    }
    if (self.idx == start and clusters[self.inPos(start)] != cluster) {
        const start_cluster = clusters[self.inPos(start)];
        var i = self.backtrackLenForMerge();
        while (i > 0 and clusters[i - 1] == start_cluster) : (i -= 1) {
            setCluster(&clusters[i - 1], &masks[i - 1], cluster, 0);
        }
    }
    for (start..end) |i| {
        const position = self.inPos(@intCast(i));
        setCluster(&clusters[position], &masks[position], cluster, 0);
    }
}

fn backtrackLenForMerge(self: *const Buffer) u32 {
    if (self.have_output) return self.out_len;
    return 0;
}

pub fn mergeOutClusters(self: *Buffer, start_in: u32, end_in: u32) void {
    if (end_in - start_in < 2) return;
    self.max_ops -= end_in - start_in;
    if (self.max_ops < 0) self.successful = false;
    var start = start_in;
    var end = end_in;
    const clusters = self.field(.cluster);
    const masks = self.field(.mask);

    var cluster = clusters[start];
    for (start + 1..end) |i| cluster = @min(cluster, clusters[i]);
    while (start > 0 and clusters[start - 1] == clusters[start]) start -= 1;
    while (end < self.out_len and clusters[end - 1] == clusters[end]) end += 1;
    if (end == self.out_len) {
        const last = clusters[end - 1];
        var i = self.idx;
        while (i < self.len and clusters[self.inPos(i)] == last) : (i += 1) {
            const position = self.inPos(i);
            setCluster(&clusters[position], &masks[position], cluster, 0);
        }
    }
    for (start..end) |i| setCluster(&clusters[i], &masks[i], cluster, 0);
}

pub fn deleteGlyph(self: *Buffer) void {
    const clusters = self.field(.cluster);
    const masks = self.field(.mask);
    const cluster = clusters[self.cur()];
    const survives_forward = self.idx + 1 < self.len and cluster == clusters[self.inPos(self.idx + 1)];
    const survives_backward = self.out_len > 0 and cluster == clusters[self.out_len - 1];
    if (!survives_forward and !survives_backward) {
        if (self.out_len > 0) {
            if (cluster < clusters[self.out_len - 1]) {
                const mask = masks[self.cur()];
                const old_cluster = clusters[self.out_len - 1];
                var i = self.out_len;
                while (i > 0 and clusters[i - 1] == old_cluster) : (i -= 1) {
                    setCluster(&clusters[i - 1], &masks[i - 1], cluster, mask);
                }
            }
        } else if (self.idx + 1 < self.len) {
            self.mergeClusters(self.idx, self.idx + 2);
        }
    }
    self.skipGlyph();
}

pub fn deleteGlyphsInplace(self: *Buffer, filter: *const fn (*Buffer, u32) bool) void {
    std.debug.assert(!self.have_output);
    var j: u32 = 0;
    const count = self.len;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (filter(self, i)) {
            const clusters = self.field(.cluster);
            const masks = self.field(.mask);
            const cluster = clusters[i];
            if (i + 1 < count and cluster == clusters[i + 1]) continue;
            if (j > 0) {
                if (cluster < clusters[j - 1]) {
                    const mask = masks[i];
                    const old_cluster = clusters[j - 1];
                    var k = j;
                    while (k > 0 and clusters[k - 1] == old_cluster) : (k -= 1) {
                        setCluster(&clusters[k - 1], &masks[k - 1], cluster, mask);
                    }
                }
                continue;
            }
            if (i + 1 < count) self.mergeClusters(i, i + 2);
            continue;
        }
        if (j != i) self.glyphs.set(j, self.glyphs.get(i));
        j += 1;
    }
    self.glyphs.shrinkRetainingCapacity(j);
    self.markMoved();
    self.len = j;
}

pub fn setMasks(self: *Buffer, value_in: u32, mask: u32, cluster_start: u32, cluster_end: u32) void {
    if (mask == 0) return;
    const value = value_in & mask;
    self.max_ops -= self.len;
    if (self.max_ops < 0) self.successful = false;
    const masks = self.field(.mask);
    const clusters = self.field(.cluster);
    for (masks[0..self.len], clusters[0..self.len]) |*glyph_mask, cluster| {
        if (cluster_start <= cluster and cluster < cluster_end) glyph_mask.* = (glyph_mask.* & ~mask) | value;
    }
}

pub fn resetMasks(self: *Buffer, mask: u32) void {
    @memset(self.field(.mask)[0..self.len], mask);
}

pub fn unsafeToBreak(self: *Buffer, start: u32, end: u32) void {
    self.setGlyphFlags(flag_unsafe_to_break | flag_unsafe_to_concat, start, end, true, false);
}

pub fn unsafeToConcat(self: *Buffer, start: u32, end: u32) void {
    self.setGlyphFlags(flag_unsafe_to_concat, start, end, false, false);
}

pub fn unsafeToBreakFromOutbuffer(self: *Buffer, start: u32, end: u32) void {
    self.setGlyphFlags(flag_unsafe_to_break | flag_unsafe_to_concat, start, end, true, true);
}

pub fn unsafeToConcatFromOutbuffer(self: *Buffer, start: u32, end: u32) void {
    self.setGlyphFlags(flag_unsafe_to_concat, start, end, false, true);
}

pub const all: u32 = std.math.maxInt(u32);

fn setGlyphFlags(self: *Buffer, mask: u32, start: u32, end_in: u32, interior: bool, from_out_buffer: bool) void {
    if (end_in != all and end_in -% start > 255) return;
    const end = @min(end_in, self.len);
    if (interior and !from_out_buffer and end -% start < 2) return;
    self.scratch.has_glyph_flags = true;
    if (!from_out_buffer or !self.have_output) {
        if (!interior) {
            var i = start;
            while (i < end) : (i += 1) self.field(.mask)[self.inPos(i)] |= mask;
            return;
        }
        const cluster = self.findMinCluster(.input, start, end, std.math.maxInt(u32));
        self.setGlyphFlagsRange(.input, start, end, cluster, mask);
        return;
    }
    std.debug.assert(start <= self.out_len);
    std.debug.assert(self.idx <= end);
    if (!interior) {
        for (start..self.out_len) |i| self.field(.mask)[i] |= mask;
        var i = self.idx;
        while (i < end) : (i += 1) self.field(.mask)[self.inPos(i)] |= mask;
        return;
    }
    var cluster = self.findMinCluster(.input, self.idx, end, std.math.maxInt(u32));
    cluster = self.findMinCluster(.output, start, self.out_len, cluster);
    self.setGlyphFlagsRange(.output, start, self.out_len, cluster, mask);
    self.setGlyphFlagsRange(.input, self.idx, end, cluster, mask);
}

const Side = enum { input, output };

fn sidePos(self: *const Buffer, side: Side, i: u32) u32 {
    return switch (side) {
        .input => self.inPos(i),
        .output => i,
    };
}

fn findMinCluster(self: *Buffer, side: Side, start: u32, end: u32, cluster: u32) u32 {
    if (start == end) return cluster;
    const clusters = self.field(.cluster);
    return @min(cluster, clusters[self.sidePos(side, start)], clusters[self.sidePos(side, end - 1)]);
}

fn setGlyphFlagsRange(self: *Buffer, side: Side, start: u32, end: u32, cluster: u32, mask: u32) void {
    if (start == end) return;
    self.max_ops -= end - start;
    if (self.max_ops < 0) self.successful = false;
    const clusters = self.field(.cluster);
    const masks = self.field(.mask);
    const first = clusters[self.sidePos(side, start)];
    const last = clusters[self.sidePos(side, end - 1)];
    if (cluster != first and cluster != last) {
        for (start..end) |i| {
            const p = self.sidePos(side, @intCast(i));
            if (cluster != clusters[p]) masks[p] |= mask;
        }
        return;
    }
    if (cluster == first) {
        var i = end;
        while (start < i and clusters[self.sidePos(side, i - 1)] != first) : (i -= 1) {
            masks[self.sidePos(side, i - 1)] |= mask;
        }
        return;
    }
    var i = start;
    while (i < end and clusters[self.sidePos(side, i)] != last) : (i += 1) {
        masks[self.sidePos(side, i)] |= mask;
    }
}

pub fn reverseRange(self: *Buffer, start: u32, end: u32) void {
    if (end - start < 2) return;
    self.markMoved();
    var a = start;
    var b = end - 1;
    while (a < b) : ({
        a += 1;
        b -= 1;
    }) self.glyphs.swap(a, b);
}

/// Stable insertion sort of `[start, end)` by `lessThan`, merging clusters of moved glyphs like HarfBuzz's `sort`.
pub fn sort(self: *Buffer, start: u32, end: u32, context: anytype, comptime lessThan: fn (@TypeOf(context), Glyph, Glyph) bool) void {
    std.debug.assert(!self.have_output);
    var i = start + 1;
    while (i < end) : (i += 1) {
        var j = i;
        const current = self.glyphs.get(i);
        while (j > start and lessThan(context, current, self.glyphs.get(j - 1))) j -= 1;
        if (i == j) continue;
        self.markMoved();
        self.mergeClusters(j, i + 1);
        const moved = self.glyphs.get(i);
        var k = i;
        while (k > j) : (k -= 1) self.glyphs.set(k, self.glyphs.get(k - 1));
        self.glyphs.set(j, moved);
    }
}

test "replace, output and delete keep input and output in one array" {
    var buffer = Buffer.init(std.testing.allocator);
    defer buffer.deinit();
    for ("abcd", 0..) |byte, index| try buffer.add(byte, @intCast(index));
    buffer.startShaping();
    buffer.clearOutput();
    buffer.nextGlyph();
    try buffer.replaceGlyphs(2, &.{ 'X', 'Y', 'Z' });
    buffer.deleteGlyph();
    buffer.sync();
    try std.testing.expectEqualSlices(u32, &.{ 'a', 'X', 'Y', 'Z' }, buffer.field(.id));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 1, 1 }, buffer.field(.cluster));
}

test "moveTo rewinds into consumed input" {
    var buffer = Buffer.init(std.testing.allocator);
    defer buffer.deinit();
    for ("abc", 0..) |byte, index| try buffer.add(byte, @intCast(index));
    buffer.startShaping();
    buffer.clearOutput();
    try buffer.outputGlyph('x');
    buffer.nextGlyph();
    buffer.nextGlyph();
    try std.testing.expect(buffer.moveTo(1));
    try std.testing.expectEqual(@as(u32, 'a'), buffer.field(.id)[buffer.cur()]);
    try std.testing.expect(buffer.moveTo(4));
    buffer.sync();
    try std.testing.expectEqualSlices(u32, &.{ 'x', 'a', 'b', 'c' }, buffer.field(.id));
}
