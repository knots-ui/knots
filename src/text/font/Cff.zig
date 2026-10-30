//! The `CFF ` table: Type 2 charstrings with global and local subroutines, including
//! CID-keyed fonts that pick local subroutines per glyph through FDSelect and FDArray.
//!
//! Hints are skipped, flex is drawn as two curves and `endchar` accents (seac) are ignored.

const std = @import("std");
const Reader = @import("Reader.zig");
const Outline = @import("Outline.zig");

cff: Reader,
charstrings: Index,
global_subrs: Index,
/// Local subroutines of the top-level Private DICT; unused by CID-keyed fonts.
local_subrs: Index,
/// FDArray of CID-keyed fonts, empty otherwise.
font_dicts: Index,
fd_select: ?Reader,

const Cff = @This();

pub const Error = error{InvalidFont};

const Vertex = Outline.Vertex;
const GlyphError = Outline.GlyphError;

const stack_max = 48;
const call_depth_max = 10;

pub const Index = struct {
    count: u32 = 0,
    offset_size: u8 = 1,
    offsets: Reader = Reader.init(&.{}),
    /// Starts at offset 1; INDEX offsets count from the byte before the data.
    data: Reader = Reader.init(&.{}),

    pub const empty: Index = .{};

    const Parsed = struct { index: Index, end: usize };

    fn parse(table: Reader, offset: usize) Reader.Error!Parsed {
        const count = try table.u16At(offset);
        if (count == 0) return .{ .index = .empty, .end = offset + 2 };
        const offset_size = try table.u8At(offset + 2);
        if (offset_size < 1 or offset_size > 4) return error.OutOfBounds;
        const offsets_len = (@as(usize, count) + 1) * offset_size;
        const offsets = try table.subLen(offset + 3, offsets_len);
        const data_start = offset + 3 + offsets_len;
        const index: Index = .{ .count = count, .offset_size = offset_size, .offsets = offsets, .data = try table.sub(data_start) };
        const last = try index.offsetAt(count);
        if (last < 1) return error.OutOfBounds;
        return .{ .index = index, .end = data_start + last - 1 };
    }

    fn offsetAt(self: Index, item: usize) Reader.Error!usize {
        const at = item * self.offset_size;
        return switch (self.offset_size) {
            1 => try self.offsets.u8At(at),
            2 => try self.offsets.u16At(at),
            3 => try self.offsets.u24At(at),
            else => try self.offsets.u32At(at),
        };
    }

    pub fn get(self: Index, item: u32) Reader.Error!Reader {
        if (item >= self.count) return error.OutOfBounds;
        const start = try self.offsetAt(item);
        const end = try self.offsetAt(@as(usize, item) + 1);
        if (start < 1 or end < start) return error.OutOfBounds;
        return self.data.subLen(start - 1, end - start);
    }
};

pub fn compile(table: Reader) Error!Cff {
    return compileTables(table) catch error.InvalidFont;
}

fn compileTables(table: Reader) (Error || Reader.Error)!Cff {
    const header_size = try table.u8At(2);
    const names = try Index.parse(table, header_size);
    const top_dicts = try Index.parse(table, names.end);
    const strings = try Index.parse(table, top_dicts.end);
    const global_subrs = try Index.parse(table, strings.end);
    const top_dict = try top_dicts.index.get(0);

    const charstrings_offset = try dictInt(top_dict, op_charstrings, 0);
    const charstring_type = try dictInt(top_dict, op_charstring_type, 2);
    const fd_array_offset = try dictInt(top_dict, op_fd_array, 0);
    const fd_select_offset = try dictInt(top_dict, op_fd_select, 0);
    if (charstring_type != 2) return error.InvalidFont;
    if (charstrings_offset <= 0) return error.InvalidFont;

    var result: Cff = .{
        .cff = table,
        .charstrings = (try Index.parse(table, @intCast(charstrings_offset))).index,
        .global_subrs = global_subrs.index,
        .local_subrs = privateSubrs(table, top_dict),
        .font_dicts = .empty,
        .fd_select = null,
    };
    if (fd_array_offset != 0) {
        if (fd_array_offset < 0 or fd_select_offset <= 0) return error.InvalidFont;
        result.font_dicts = (try Index.parse(table, @intCast(fd_array_offset))).index;
        result.fd_select = try table.sub(@intCast(fd_select_offset));
    }
    return result;
}

const op_charstrings = 17;
const op_private = 18;
const op_subrs = 19;
const op_charstring_type = 0x100 | 6;
const op_fd_array = 0x100 | 36;
const op_fd_select = 0x100 | 37;

/// The Subrs INDEX of the Private DICT that `dict` points to, or empty.
fn privateSubrs(table: Reader, dict: Reader) Index {
    var location: [2]i32 = .{ 0, 0 };
    _ = dictInts(dict, op_private, &location) catch return .empty;
    const size, const offset = location;
    if (size <= 0 or offset <= 0) return .empty;
    const private = table.subLen(@intCast(offset), @intCast(size)) catch return .empty;
    const subrs_offset = dictInt(private, op_subrs, 0) catch return .empty;
    if (subrs_offset <= 0) return .empty;
    const start = @as(usize, @intCast(offset)) + @as(usize, @intCast(subrs_offset));
    return (Index.parse(table, start) catch return .empty).index;
}

fn dictInt(dict: Reader, key: u16, default: i32) Reader.Error!i32 {
    var value: [1]i32 = .{default};
    _ = try dictInts(dict, key, &value);
    return value[0];
}

/// Reads up to `out.len` integer operands of the first `key` entry. Missing operands keep
/// their value.
fn dictInts(dict: Reader, key: u16, out: []i32) Reader.Error!usize {
    var offset: usize = 0;
    while (offset < dict.bytes.len) {
        const operands_start = offset;
        while (try dict.u8At(offset) >= 28) offset = try skipOperand(dict, offset);
        const operands_end = offset;
        var op: u16 = try dict.u8At(offset);
        offset += 1;
        if (op == 12) {
            op = 0x100 | @as(u16, try dict.u8At(offset));
            offset += 1;
        }
        if (op != key) continue;
        var cursor = operands_start;
        var count: usize = 0;
        while (cursor < operands_end and count < out.len) : (count += 1) {
            const operand = try dictOperand(dict, cursor);
            out[count] = operand.value;
            cursor = operand.end;
        }
        return count;
    }
    return 0;
}

const Operand = struct { value: i32, end: usize };

fn dictOperand(dict: Reader, offset: usize) Reader.Error!Operand {
    const b0 = try dict.u8At(offset);
    return switch (b0) {
        28 => .{ .value = try dict.i16At(offset + 1), .end = offset + 3 },
        29 => .{ .value = @bitCast(try dict.u32At(offset + 1)), .end = offset + 5 },
        32...246 => .{ .value = @as(i32, b0) - 139, .end = offset + 1 },
        247...250 => .{ .value = (@as(i32, b0) - 247) * 256 + try dict.u8At(offset + 1) + 108, .end = offset + 2 },
        251...254 => .{ .value = -(@as(i32, b0) - 251) * 256 - try dict.u8At(offset + 1) - 108, .end = offset + 2 },
        else => error.OutOfBounds,
    };
}

fn skipOperand(dict: Reader, offset: usize) Reader.Error!usize {
    if (try dict.u8At(offset) != 30) return (try dictOperand(dict, offset)).end;
    // Real number: nibbles up to and including the one that holds 0xF.
    var cursor = offset + 1;
    while (true) {
        const byte = try dict.u8At(cursor);
        cursor += 1;
        if (byte & 0xF == 0xF or byte >> 4 == 0xF) return cursor;
    }
}

/// Local subroutines for `glyph_id` in a CID-keyed font, chosen through FDSelect.
fn fontDictSubrs(self: *const Cff, glyph_id: u16) Index {
    const fd_select = self.fd_select orelse return self.local_subrs;
    const font_dict = blk: {
        const format = fd_select.u8At(0) catch return .empty;
        switch (format) {
            0 => break :blk fd_select.u8At(1 + @as(usize, glyph_id)) catch return .empty,
            3 => {
                const range_count = fd_select.u16At(1) catch return .empty;
                var first = fd_select.u16At(3) catch return .empty;
                for (0..range_count) |range| {
                    const font_dict = fd_select.u8At(5 + range * 3) catch return .empty;
                    const end = fd_select.u16At(5 + range * 3 + 1) catch return .empty;
                    if (glyph_id >= first and glyph_id < end) break :blk font_dict;
                    first = end;
                }
                return .empty;
            },
            else => return .empty,
        }
    };
    const dict = self.font_dicts.get(font_dict) catch return .empty;
    return privateSubrs(self.cff, dict);
}

fn subroutine(subrs: Index, number: f32) GlyphError!Reader {
    const bias: i64 = if (subrs.count < 1240) 107 else if (subrs.count < 33900) 1131 else 32768;
    if (!(@abs(number) < 65536.0)) return error.InvalidGlyph;
    const item = @as(i64, @intFromFloat(number)) + bias;
    if (item < 0 or item >= subrs.count) return error.InvalidGlyph;
    return subrs.get(@intCast(item));
}

/// The current point and the start of the open contour, in unrounded font units.
const Pen = struct {
    gpa: std.mem.Allocator,
    vertices: *std.ArrayList(Vertex),
    first_x: f32 = 0,
    first_y: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,

    fn close(self: *Pen) GlyphError!void {
        if (self.first_x == self.x and self.first_y == self.y) return;
        try self.vertices.append(self.gpa, .{ .kind = .line, .x = try Outline.truncate(self.first_x), .y = try Outline.truncate(self.first_y) });
    }

    fn moveTo(self: *Pen, dx: f32, dy: f32) GlyphError!void {
        try self.close();
        self.first_x = self.x + dx;
        self.first_y = self.y + dy;
        self.x = self.first_x;
        self.y = self.first_y;
        try self.vertices.append(self.gpa, .{ .kind = .move, .x = try Outline.truncate(self.x), .y = try Outline.truncate(self.y) });
    }

    fn lineTo(self: *Pen, dx: f32, dy: f32) GlyphError!void {
        self.x += dx;
        self.y += dy;
        try self.vertices.append(self.gpa, .{ .kind = .line, .x = try Outline.truncate(self.x), .y = try Outline.truncate(self.y) });
    }

    fn curveTo(self: *Pen, dx1: f32, dy1: f32, dx2: f32, dy2: f32, dx3: f32, dy3: f32) GlyphError!void {
        const cx1 = self.x + dx1;
        const cy1 = self.y + dy1;
        const cx2 = cx1 + dx2;
        const cy2 = cy1 + dy2;
        self.x = cx2 + dx3;
        self.y = cy2 + dy3;
        try self.vertices.append(self.gpa, .{
            .kind = .cubic,
            .x = try Outline.truncate(self.x),
            .y = try Outline.truncate(self.y),
            .cx = try Outline.truncate(cx1),
            .cy = try Outline.truncate(cy1),
            .cx1 = try Outline.truncate(cx2),
            .cy1 = try Outline.truncate(cy2),
        });
    }
};

const Frame = struct { program: Reader, offset: usize };

/// Runs the charstring of `glyph_id`, appending its outline. The advance width operand is
/// ignored; `hmtx` is authoritative.
pub fn appendGlyph(self: *const Cff, gpa: std.mem.Allocator, glyph_id: u16, vertices: *std.ArrayList(Vertex)) GlyphError!void {
    var pen: Pen = .{ .gpa = gpa, .vertices = vertices };
    var stack: [stack_max]f32 = @splat(0);
    var sp: usize = 0;
    var calls: [call_depth_max]Frame = undefined;
    var call_depth: usize = 0;
    var local_subrs: ?Index = null;
    var mask_bits: usize = 0;
    var in_header = true;

    var program = try self.charstrings.get(glyph_id);
    var offset: usize = 0;
    while (offset < program.bytes.len) {
        const b0 = try program.u8At(offset);
        offset += 1;
        var clear_stack = true;
        var index: usize = 0;
        const s = stack[0..sp];
        switch (b0) {
            // hstem, vstem, hstemhm, vstemhm
            0x01, 0x03, 0x12, 0x17 => mask_bits += sp / 2,
            // hintmask, cntrmask
            0x13, 0x14 => {
                // Stems before the first mask are an implicit vstem.
                if (in_header) mask_bits += sp / 2;
                in_header = false;
                offset += (mask_bits + 7) / 8;
            },
            // rmoveto
            0x15 => {
                in_header = false;
                if (sp < 2) return error.InvalidGlyph;
                try pen.moveTo(s[sp - 2], s[sp - 1]);
            },
            // vmoveto
            0x04 => {
                in_header = false;
                if (sp < 1) return error.InvalidGlyph;
                try pen.moveTo(0, s[sp - 1]);
            },
            // hmoveto
            0x16 => {
                in_header = false;
                if (sp < 1) return error.InvalidGlyph;
                try pen.moveTo(s[sp - 1], 0);
            },
            // rlineto
            0x05 => {
                if (sp < 2) return error.InvalidGlyph;
                while (index + 1 < sp) : (index += 2) try pen.lineTo(s[index], s[index + 1]);
            },
            // vlineto, hlineto: alternate vertical and horizontal lines.
            0x07, 0x06 => {
                if (sp < 1) return error.InvalidGlyph;
                var vertical = b0 == 0x07;
                while (index < sp) : (index += 1) {
                    if (vertical) try pen.lineTo(0, s[index]) else try pen.lineTo(s[index], 0);
                    vertical = !vertical;
                }
            },
            // hvcurveto, vhcurveto: alternate horizontal and vertical tangents.
            0x1F, 0x1E => {
                if (sp < 4) return error.InvalidGlyph;
                var horizontal = b0 == 0x1F;
                while (index + 3 < sp) : (index += 4) {
                    const last: f32 = if (sp - index == 5) s[index + 4] else 0;
                    if (horizontal) {
                        try pen.curveTo(s[index], 0, s[index + 1], s[index + 2], last, s[index + 3]);
                    } else {
                        try pen.curveTo(0, s[index], s[index + 1], s[index + 2], s[index + 3], last);
                    }
                    horizontal = !horizontal;
                }
            },
            // rrcurveto
            0x08 => {
                if (sp < 6) return error.InvalidGlyph;
                while (index + 5 < sp) : (index += 6) {
                    try pen.curveTo(s[index], s[index + 1], s[index + 2], s[index + 3], s[index + 4], s[index + 5]);
                }
            },
            // rcurveline
            0x18 => {
                if (sp < 8) return error.InvalidGlyph;
                while (index + 5 < sp - 2) : (index += 6) {
                    try pen.curveTo(s[index], s[index + 1], s[index + 2], s[index + 3], s[index + 4], s[index + 5]);
                }
                if (index + 1 >= sp) return error.InvalidGlyph;
                try pen.lineTo(s[index], s[index + 1]);
            },
            // rlinecurve
            0x19 => {
                if (sp < 8) return error.InvalidGlyph;
                while (index + 1 < sp - 6) : (index += 2) try pen.lineTo(s[index], s[index + 1]);
                if (index + 5 >= sp) return error.InvalidGlyph;
                try pen.curveTo(s[index], s[index + 1], s[index + 2], s[index + 3], s[index + 4], s[index + 5]);
            },
            // vvcurveto, hhcurveto
            0x1A, 0x1B => {
                if (sp < 4) return error.InvalidGlyph;
                var first: f32 = 0;
                if (sp & 1 != 0) {
                    first = s[0];
                    index = 1;
                }
                while (index + 3 < sp) : (index += 4) {
                    if (b0 == 0x1B) {
                        try pen.curveTo(s[index], first, s[index + 1], s[index + 2], s[index + 3], 0);
                    } else {
                        try pen.curveTo(first, s[index], s[index + 1], s[index + 2], 0, s[index + 3]);
                    }
                    first = 0;
                }
            },
            // callsubr, callgsubr
            0x0A, 0x1D => {
                if (sp < 1) return error.InvalidGlyph;
                sp -= 1;
                const subrs = if (b0 == 0x1D) self.global_subrs else local: {
                    if (local_subrs == null) local_subrs = self.fontDictSubrs(glyph_id);
                    break :local local_subrs.?;
                };
                if (call_depth >= call_depth_max) return error.InvalidGlyph;
                calls[call_depth] = .{ .program = program, .offset = offset };
                call_depth += 1;
                program = try subroutine(subrs, stack[sp]);
                if (program.bytes.len == 0) return error.InvalidGlyph;
                offset = 0;
                clear_stack = false;
            },
            // return
            0x0B => {
                if (call_depth == 0) return error.InvalidGlyph;
                call_depth -= 1;
                program = calls[call_depth].program;
                offset = calls[call_depth].offset;
                clear_stack = false;
            },
            // endchar
            0x0E => return pen.close(),
            0x0C => {
                const b1 = try program.u8At(offset);
                offset += 1;
                try flex(&pen, b1, s);
            },
            else => {
                if (b0 != 255 and b0 != 28 and b0 < 32) return error.InvalidGlyph;
                if (sp >= stack_max) return error.InvalidGlyph;
                const number = try charstringNumber(program, offset - 1);
                stack[sp] = number.value;
                sp += 1;
                offset = number.end;
                clear_stack = false;
            },
        }
        if (clear_stack) sp = 0;
    }
    // Charstrings and subroutines end with `endchar` or `return`.
    return error.InvalidGlyph;
}

/// The flex family, always drawn as two curves; flex depth is ignored.
fn flex(pen: *Pen, op: u8, s: []const f32) GlyphError!void {
    switch (op) {
        // hflex
        34 => {
            if (s.len < 7) return error.InvalidGlyph;
            try pen.curveTo(s[0], 0, s[1], s[2], s[3], 0);
            try pen.curveTo(s[4], 0, s[5], -s[2], s[6], 0);
        },
        // flex
        35 => {
            if (s.len < 13) return error.InvalidGlyph;
            try pen.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
            try pen.curveTo(s[6], s[7], s[8], s[9], s[10], s[11]);
        },
        // hflex1
        36 => {
            if (s.len < 9) return error.InvalidGlyph;
            try pen.curveTo(s[0], s[1], s[2], s[3], s[4], 0);
            try pen.curveTo(s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]));
        },
        // flex1
        37 => {
            if (s.len < 11) return error.InvalidGlyph;
            const dx = s[0] + s[2] + s[4] + s[6] + s[8];
            const dy = s[1] + s[3] + s[5] + s[7] + s[9];
            var dx6 = s[10];
            var dy6 = s[10];
            if (@abs(dx) > @abs(dy)) dy6 = -dy else dx6 = -dx;
            try pen.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
            try pen.curveTo(s[6], s[7], s[8], s[9], dx6, dy6);
        },
        else => return error.InvalidGlyph,
    }
}

const Number = struct { value: f32, end: usize };

fn charstringNumber(program: Reader, offset: usize) Reader.Error!Number {
    const b0 = try program.u8At(offset);
    return switch (b0) {
        28 => .{ .value = @floatFromInt(try program.i16At(offset + 1)), .end = offset + 3 },
        // 16.16 fixed point.
        255 => .{ .value = @as(f32, @floatFromInt(@as(i32, @bitCast(try program.u32At(offset + 1))))) / 65536.0, .end = offset + 5 },
        32...246 => .{ .value = @floatFromInt(@as(i32, b0) - 139), .end = offset + 1 },
        247...250 => .{ .value = @floatFromInt((@as(i32, b0) - 247) * 256 + try program.u8At(offset + 1) + 108), .end = offset + 2 },
        251...254 => .{ .value = @floatFromInt(-(@as(i32, b0) - 251) * 256 - try program.u8At(offset + 1) - 108), .end = offset + 2 },
        else => error.OutOfBounds,
    };
}

test "parses an INDEX and rejects bad offset sizes" {
    // count 2, offSize 1, offsets 1 3 4, data "abc".
    const bytes = [_]u8{ 0, 2, 1, 1, 3, 4, 'a', 'b', 'c', 0xff };
    const parsed = try Index.parse(Reader.init(&bytes), 0);
    try std.testing.expectEqual(@as(usize, 9), parsed.end);
    try std.testing.expectEqualStrings("ab", (try parsed.index.get(0)).bytes);
    try std.testing.expectEqualStrings("c", (try parsed.index.get(1)).bytes);
    try std.testing.expectError(error.OutOfBounds, parsed.index.get(2));
    try std.testing.expectError(error.OutOfBounds, Index.parse(Reader.init(&.{ 0, 1, 5, 1, 1 }), 0));
}

test "runs a charstring with subroutines and flex" {
    const gpa = std.testing.allocator;
    // Global subr 0 (biased number -107) draws a line and returns.
    const global = [_]u8{ 0, 1, 1, 1, 5, 139 + 10, 139, 0x05, 0x0B };
    // 10 20 rmoveto, callgsubr, 0 0 10 10 20 0 30 0 40 -10 50 -10 50 flex, endchar.
    const charstring = [_]u8{ 149, 159, 0x15, 32, 0x1D } ++
        [_]u8{ 139, 139, 149, 149, 159, 139, 169, 139, 179, 129, 189, 129, 189, 0x0C, 35 } ++ [_]u8{0x0E};
    const charstrings = [_]u8{ 0, 1, 1, 1, charstring.len + 1 } ++ charstring;
    const cff: Cff = .{
        .cff = Reader.init(&.{}),
        .charstrings = (try Index.parse(Reader.init(&charstrings), 0)).index,
        .global_subrs = (try Index.parse(Reader.init(&global), 0)).index,
        .local_subrs = .empty,
        .font_dicts = .empty,
        .fd_select = null,
    };
    var vertices: std.ArrayList(Vertex) = .empty;
    defer vertices.deinit(gpa);
    try cff.appendGlyph(gpa, 0, &vertices);
    const kinds = [_]Vertex.Kind{ .move, .line, .cubic, .cubic, .line };
    try std.testing.expectEqual(kinds.len, vertices.items.len);
    for (kinds, vertices.items) |kind, vertex| try std.testing.expectEqual(kind, vertex.kind);
    try std.testing.expectEqual(@as(i32, 20), vertices.items[1].x);
    try std.testing.expectEqual(@as(i32, 10), vertices.items[4].x);
    try std.testing.expectEqual(@as(i32, 20), vertices.items[4].y);

    try std.testing.expectError(error.OutOfBounds, cff.appendGlyph(gpa, 1, &vertices));
}
