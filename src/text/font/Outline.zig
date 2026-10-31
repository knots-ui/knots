//! Glyph outlines in font units, from `glyf`/`loca` or the `CFF ` table.
//!
//! The decomposition follows stb_truetype so rendered glyphs stay stable: implied on-curve
//! points are midpoints rounded toward negative infinity, every contour ends with an explicit
//! closing segment, and transformed composite components are truncated to integers. Unlike
//! stb_truetype, a component's matrix is applied once; stb also multiplies by the matrix's
//! column lengths, scaling scaled components (and their offsets) twice.

const std = @import("std");
const Reader = @import("Reader.zig");
const sfnt = @import("sfnt.zig");
const Cff = @import("Cff.zig");

source: Source,
glyph_count: u16,

const Outline = @This();

pub const Source = union(enum) {
    none,
    glyf: Glyf,
    cff: Cff,
};

pub const Glyf = struct {
    glyf: Reader,
    loca: Reader,
    long_offsets: bool,
};

pub const Vertex = struct {
    kind: Kind,
    /// End point; the start of a new contour for `move`.
    x: i32,
    y: i32,
    /// Control point of `quad`, first control point of `cubic`.
    cx: i32 = 0,
    cy: i32 = 0,
    /// Second control point of `cubic`.
    cx1: i32 = 0,
    cy1: i32 = 0,

    pub const Kind = enum(u8) { move, line, quad, cubic };
};

pub const Error = error{OutOfMemory};

/// Malformed glyph data. The glyph is dropped as a whole.
pub const GlyphError = error{ OutOfMemory, InvalidGlyph } || Reader.Error;

pub const empty: Outline = .{ .source = .none, .glyph_count = 0 };

/// Composite glyphs nested deeper than this are malformed (or cyclic).
const composite_depth_max = 16;

pub fn compile(directory: sfnt.Directory, glyph_count: u16) Outline {
    if (directory.table("glyf")) |glyf| {
        const loca = directory.table("loca") orelse return empty;
        const head = directory.table("head") orelse return empty;
        const format = head.i16At(50) catch return empty;
        if (format != 0 and format != 1) return empty;
        return .{
            .source = .{ .glyf = .{ .glyf = glyf, .loca = loca, .long_offsets = format == 1 } },
            .glyph_count = glyph_count,
        };
    }
    const table = directory.table("CFF ") orelse return empty;
    const cff = Cff.compile(table) catch return empty;
    return .{ .source = .{ .cff = cff }, .glyph_count = glyph_count };
}

/// Appends the outline of `glyph_id` to `vertices`. Leaves `vertices` unchanged for empty,
/// malformed and out-of-range glyphs.
pub fn glyph(self: *const Outline, gpa: std.mem.Allocator, glyph_id: u32, vertices: *std.ArrayList(Vertex)) Error!void {
    if (glyph_id >= self.glyph_count) return;
    const id: u16 = @intCast(glyph_id);
    const start = vertices.items.len;
    const result = switch (self.source) {
        .none => {},
        .glyf => |glyf| appendGlyf(glyf, gpa, self.glyph_count, id, vertices, 0),
        .cff => |cff| cff.appendGlyph(gpa, id, vertices),
    };
    result catch |err| {
        vertices.shrinkRetainingCapacity(start);
        if (err == error.OutOfMemory) return error.OutOfMemory;
    };
}

fn glyphData(glyf: Glyf, id: u16) Reader.Error!?Reader {
    const start: usize, const end: usize = if (glyf.long_offsets) .{
        try glyf.loca.u32At(@as(usize, id) * 4),
        try glyf.loca.u32At(@as(usize, id) * 4 + 4),
    } else .{
        @as(usize, try glyf.loca.u16At(@as(usize, id) * 2)) * 2,
        @as(usize, try glyf.loca.u16At(@as(usize, id) * 2 + 2)) * 2,
    };
    if (start == end) return null;
    if (end < start) return error.OutOfBounds;
    return try glyf.glyf.subLen(start, end - start);
}

fn appendGlyf(glyf: Glyf, gpa: std.mem.Allocator, glyph_count: u16, id: u16, vertices: *std.ArrayList(Vertex), depth: u32) GlyphError!void {
    const data = try glyphData(glyf, id) orelse return;
    const contour_count = try data.i16At(0);
    if (contour_count > 0) {
        try appendSimple(gpa, data, @intCast(contour_count), vertices);
    } else if (contour_count < 0) {
        if (depth >= composite_depth_max) return error.InvalidGlyph;
        try appendComposite(glyf, gpa, glyph_count, data, vertices, depth);
    }
}

const Point = struct {
    x: i32,
    y: i32,
    on_curve: bool,
};

/// Walks the flag, x and y streams of a simple glyph in step.
const Points = struct {
    data: Reader,
    flag_offset: usize,
    x_offset: usize,
    y_offset: usize,
    flag: u8 = 0,
    repeat: u8 = 0,
    x: i32 = 0,
    y: i32 = 0,

    fn init(data: Reader, flags_offset: usize, point_count: u32) Reader.Error!Points {
        var offset = flags_offset;
        var x_size: usize = 0;
        var remaining = point_count;
        while (remaining > 0) {
            const flag = try data.u8At(offset);
            offset += 1;
            var count: u32 = 1;
            if (flag & 8 != 0) {
                count += try data.u8At(offset);
                offset += 1;
            }
            count = @min(count, remaining);
            remaining -= count;
            if (flag & 2 != 0) {
                x_size += count;
            } else if (flag & 16 == 0) {
                x_size += count * 2;
            }
        }
        return .{ .data = data, .flag_offset = flags_offset, .x_offset = offset, .y_offset = offset + x_size };
    }

    fn next(self: *Points) Reader.Error!Point {
        if (self.repeat == 0) {
            self.flag = try self.data.u8At(self.flag_offset);
            self.flag_offset += 1;
            if (self.flag & 8 != 0) {
                self.repeat = try self.data.u8At(self.flag_offset);
                self.flag_offset += 1;
            }
        } else {
            self.repeat -= 1;
        }
        self.x += try self.delta(&self.x_offset, 2, 16);
        self.y += try self.delta(&self.y_offset, 4, 32);
        return .{ .x = self.x, .y = self.y, .on_curve = self.flag & 1 != 0 };
    }

    fn delta(self: *const Points, offset: *usize, short_bit: u8, same_bit: u8) Reader.Error!i32 {
        if (self.flag & short_bit != 0) {
            const magnitude: i32 = try self.data.u8At(offset.*);
            offset.* += 1;
            return if (self.flag & same_bit != 0) magnitude else -magnitude;
        }
        if (self.flag & same_bit != 0) return 0;
        const value = try self.data.i16At(offset.*);
        offset.* += 2;
        return value;
    }
};

fn appendSimple(gpa: std.mem.Allocator, data: Reader, contour_count: u16, vertices: *std.ArrayList(Vertex)) GlyphError!void {
    const end_points = try data.subLen(10, @as(usize, contour_count) * 2);
    const instructions_offset = 10 + @as(usize, contour_count) * 2;
    const instruction_len = try data.u16At(instructions_offset);
    const point_count: u32 = @as(u32, try end_points.u16At(end_points.bytes.len - 2)) + 1;
    var points = try Points.init(data, instructions_offset + 2 + instruction_len, point_count);
    try vertices.ensureUnusedCapacity(gpa, point_count + 2 * @as(usize, contour_count));

    var contour: Contour = .{};
    var next_move: u32 = 0;
    var contour_index: usize = 0;
    var index: u32 = 0;
    while (index < point_count) : (index += 1) {
        const point = try points.next();
        if (index == next_move) {
            if (index != 0) try contour.close(gpa, vertices);
            contour = .{ .start_off = !point.on_curve };
            if (contour.start_off) {
                // Start on the next on-curve point, or between two off-curve points.
                contour.start_control = .{ point.x, point.y };
                if (index + 1 >= point_count) return error.InvalidGlyph;
                var peek = points;
                const following = try peek.next();
                if (following.on_curve) {
                    contour.start = .{ following.x, following.y };
                    points = peek;
                    index += 1;
                } else {
                    contour.start = .{ (point.x + following.x) >> 1, (point.y + following.y) >> 1 };
                }
            } else {
                contour.start = .{ point.x, point.y };
            }
            try vertices.append(gpa, .{ .kind = .move, .x = contour.start[0], .y = contour.start[1] });
            next_move = @as(u32, try end_points.u16At(contour_index * 2)) + 1;
            contour_index += 1;
        } else if (!point.on_curve) {
            if (contour.was_off) {
                try vertices.append(gpa, .{
                    .kind = .quad,
                    .x = (contour.control[0] + point.x) >> 1,
                    .y = (contour.control[1] + point.y) >> 1,
                    .cx = contour.control[0],
                    .cy = contour.control[1],
                });
            }
            contour.control = .{ point.x, point.y };
            contour.was_off = true;
        } else {
            if (contour.was_off) {
                try vertices.append(gpa, .{ .kind = .quad, .x = point.x, .y = point.y, .cx = contour.control[0], .cy = contour.control[1] });
            } else {
                try vertices.append(gpa, .{ .kind = .line, .x = point.x, .y = point.y });
            }
            contour.was_off = false;
        }
    }
    try contour.close(gpa, vertices);
}

const Contour = struct {
    start: [2]i32 = .{ 0, 0 },
    start_control: [2]i32 = .{ 0, 0 },
    control: [2]i32 = .{ 0, 0 },
    start_off: bool = false,
    was_off: bool = false,

    fn close(self: Contour, gpa: std.mem.Allocator, vertices: *std.ArrayList(Vertex)) error{OutOfMemory}!void {
        if (self.start_off) {
            if (self.was_off) {
                try vertices.append(gpa, .{
                    .kind = .quad,
                    .x = (self.control[0] + self.start_control[0]) >> 1,
                    .y = (self.control[1] + self.start_control[1]) >> 1,
                    .cx = self.control[0],
                    .cy = self.control[1],
                });
            }
            try vertices.append(gpa, .{ .kind = .quad, .x = self.start[0], .y = self.start[1], .cx = self.start_control[0], .cy = self.start_control[1] });
        } else if (self.was_off) {
            try vertices.append(gpa, .{ .kind = .quad, .x = self.start[0], .y = self.start[1], .cx = self.control[0], .cy = self.control[1] });
        } else {
            try vertices.append(gpa, .{ .kind = .line, .x = self.start[0], .y = self.start[1] });
        }
    }
};

const arg_1_and_2_are_words = 1 << 0;
const args_are_xy_values = 1 << 1;
const we_have_a_scale = 1 << 3;
const more_components = 1 << 5;
const we_have_an_x_and_y_scale = 1 << 6;
const we_have_a_two_by_two = 1 << 7;

fn appendComposite(glyf: Glyf, gpa: std.mem.Allocator, glyph_count: u16, data: Reader, vertices: *std.ArrayList(Vertex), depth: u32) GlyphError!void {
    var offset: usize = 10;
    while (true) {
        const flags = try data.u16At(offset);
        const component = try data.u16At(offset + 2);
        offset += 4;

        // Row-major 2x2 matrix followed by the offset.
        var matrix: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };
        if (flags & arg_1_and_2_are_words != 0) {
            if (flags & args_are_xy_values != 0) {
                matrix[4] = @floatFromInt(try data.i16At(offset));
                matrix[5] = @floatFromInt(try data.i16At(offset + 2));
            }
            offset += 4;
        } else {
            if (flags & args_are_xy_values != 0) {
                matrix[4] = @floatFromInt(@as(i8, @bitCast(try data.u8At(offset))));
                matrix[5] = @floatFromInt(@as(i8, @bitCast(try data.u8At(offset + 1))));
            }
            offset += 2;
        }
        // Anchoring by matching point numbers is unsupported; such components sit at the origin.
        if (flags & we_have_a_scale != 0) {
            matrix[0] = try f2dot14(data, offset);
            matrix[3] = matrix[0];
            offset += 2;
        } else if (flags & we_have_an_x_and_y_scale != 0) {
            matrix[0] = try f2dot14(data, offset);
            matrix[3] = try f2dot14(data, offset + 2);
            offset += 4;
        } else if (flags & we_have_a_two_by_two != 0) {
            matrix[0] = try f2dot14(data, offset);
            matrix[1] = try f2dot14(data, offset + 2);
            matrix[2] = try f2dot14(data, offset + 4);
            matrix[3] = try f2dot14(data, offset + 6);
            offset += 8;
        }

        const component_start = vertices.items.len;
        if (component < glyph_count) try appendGlyf(glyf, gpa, glyph_count, component, vertices, depth + 1);
        for (vertices.items[component_start..]) |*vertex| {
            vertex.x, vertex.y = try transform(matrix, vertex.x, vertex.y);
            vertex.cx, vertex.cy = try transform(matrix, vertex.cx, vertex.cy);
        }
        if (flags & more_components == 0) break;
    }
}

fn f2dot14(data: Reader, offset: usize) Reader.Error!f32 {
    return @as(f32, @floatFromInt(try data.i16At(offset))) / 16384.0;
}

fn transform(matrix: [6]f32, x_int: i32, y_int: i32) error{InvalidGlyph}!struct { i32, i32 } {
    const x: f32 = @floatFromInt(x_int);
    const y: f32 = @floatFromInt(y_int);
    return .{
        try truncate(matrix[0] * x + matrix[2] * y + matrix[4]),
        try truncate(matrix[1] * x + matrix[3] * y + matrix[5]),
    };
}

/// Float to font units, truncating toward zero.
pub fn truncate(value: f32) error{InvalidGlyph}!i32 {
    if (!(@abs(value) < 2147483648.0)) return error.InvalidGlyph;
    return @intFromFloat(value);
}

test "decodes simple and composite glyphs of the bundled font" {
    const gpa = std.testing.allocator;
    const data = @embedFile("test_font");
    const directory = try sfnt.open(data, 0);
    const maxp = directory.table("maxp").?;
    const outline = compile(directory, try maxp.u16At(4));
    try std.testing.expect(outline.source == .glyf);

    var vertices: std.ArrayList(Vertex) = .empty;
    defer vertices.deinit(gpa);
    var composites: usize = 0;
    for (0..outline.glyph_count) |id| {
        vertices.clearRetainingCapacity();
        try outline.glyph(gpa, @intCast(id), &vertices);
        const glyph_data = (try glyphData(outline.source.glyf, @intCast(id))) orelse continue;
        if (try glyph_data.i16At(0) < 0) composites += 1;
        try std.testing.expect(vertices.items.len > 0);
        try std.testing.expectEqual(Vertex.Kind.move, vertices.items[0].kind);
    }
    try std.testing.expect(composites > 0);

    vertices.clearRetainingCapacity();
    try outline.glyph(gpa, outline.glyph_count, &vertices);
    try outline.glyph(gpa, 0x1_0000, &vertices);
    try std.testing.expectEqual(@as(usize, 0), vertices.items.len);
}

test "truncated and mutated glyph data never panics" {
    const gpa = std.testing.allocator;
    const original = @embedFile("test_font");
    const data = try gpa.dupe(u8, original);
    defer gpa.free(data);
    const directory = try sfnt.open(original, 0);
    const glyf = directory.table("glyf").?;
    const base = @intFromPtr(glyf.bytes.ptr) - @intFromPtr(original.ptr);
    const glyph_count = try directory.table("maxp").?.u16At(4);

    var vertices: std.ArrayList(Vertex) = .empty;
    defer vertices.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(0x071e);
    const random = prng.random();
    for (0..200) |_| {
        @memcpy(data, original);
        for (0..random.intRangeAtMost(usize, 1, 16)) |_| {
            data[base + random.uintLessThan(usize, glyf.bytes.len)] = random.int(u8);
        }
        const outline = compile(try sfnt.open(data, 0), glyph_count);
        for (0..64) |_| {
            vertices.clearRetainingCapacity();
            try outline.glyph(gpa, random.uintLessThan(u32, glyph_count), &vertices);
        }
    }
}
