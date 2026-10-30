//! Per-font digests of the compiled cmap, advances and glyph outlines. `zig build digests`
//! records them and `zig build test` flags any change, so a regression in font parsing
//! shows up even for glyphs no shaping case reaches.

const std = @import("std");
const text = @import("text");

pub const path = "tests/shaping/digests.txt";

pub const Digest = struct {
    glyphs: u32,
    cmap: u64,
    advances: u64,
    outlines: u64,
};

pub fn compute(gpa: std.mem.Allocator, program: *const text.FontProgram) !Digest {
    var cmap: std.hash.Wyhash = .init(0);
    var codepoint: u21 = 0;
    while (codepoint <= text.Cmap.codepoint_max) : (codepoint += 1) {
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) continue;
        hashInt(&cmap, u16, program.cmap.glyph(codepoint));
    }

    var advances: std.hash.Wyhash = .init(0);
    var outlines: std.hash.Wyhash = .init(0);
    var vertices: std.ArrayList(text.Outline.Vertex) = .empty;
    defer vertices.deinit(gpa);
    const units_per_em: f32 = @floatFromInt(program.units_per_em);
    for (0..program.glyph_count) |glyph_id| {
        hashInt(&advances, u16, program.advance(@intCast(glyph_id)));
        vertices.clearRetainingCapacity();
        try program.outline.glyph(gpa, @intCast(glyph_id), &vertices);
        const curves = try text.curve.decomposeVertices(gpa, vertices.items, units_per_em);
        defer gpa.free(curves);
        hashInt(&outlines, u32, @intCast(curves.len));
        for (curves) |curve| {
            for ([_][2]f32{ curve.p1, curve.p2, curve.p3 }) |point| {
                hashInt(&outlines, u32, @bitCast(point[0]));
                hashInt(&outlines, u32, @bitCast(point[1]));
            }
        }
    }
    return .{ .glyphs = program.glyph_count, .cmap = cmap.final(), .advances = advances.final(), .outlines = outlines.final() };
}

fn hashInt(hasher: *std.hash.Wyhash, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

pub fn appendLine(arena: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, digest: Digest) !void {
    try out.print(arena, "{s} | {d} | {x:0>16} | {x:0>16} | {x:0>16}\n", .{ name, digest.glyphs, digest.cmap, digest.advances, digest.outlines });
}

/// The recorded digest of `name`, or null when it has none or its line is malformed.
pub fn find(source: []const u8, name: []const u8) ?Digest {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, trimmed, '|');
        const font = std.mem.trim(u8, fields.next() orelse continue, " \t");
        if (!std.mem.eql(u8, font, name)) continue;
        return parseFields(&fields) catch null;
    }
    return null;
}

fn parseFields(fields: *std.mem.SplitIterator(u8, .scalar)) !Digest {
    return .{
        .glyphs = try std.fmt.parseInt(u32, try nextField(fields), 10),
        .cmap = try std.fmt.parseInt(u64, try nextField(fields), 16),
        .advances = try std.fmt.parseInt(u64, try nextField(fields), 16),
        .outlines = try std.fmt.parseInt(u64, try nextField(fields), 16),
    };
}

fn nextField(fields: *std.mem.SplitIterator(u8, .scalar)) ![]const u8 {
    return std.mem.trim(u8, fields.next() orelse return error.MissingField, " \t");
}
