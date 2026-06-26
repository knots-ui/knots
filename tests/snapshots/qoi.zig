const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.rgba);
        self.* = undefined;
    }
};

pub fn encode(allocator: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) ![]u8 {
    const row_len = std.math.mul(usize, @as(usize, width), 4) catch return error.InvalidImage;
    const image_len = std.math.mul(usize, row_len, @as(usize, height)) catch return error.InvalidImage;
    if (rgba.len != image_len) return error.InvalidImage;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "qoif");
    try appendU32(&out, allocator, width);
    try appendU32(&out, allocator, height);
    try out.appendSlice(allocator, &.{ 4, 0 });

    var previous = [4]u8{ 0, 0, 0, 255 };
    var run: u8 = 0;
    var offset: usize = 0;
    while (offset < rgba.len) : (offset += 4) {
        const pixel: [4]u8 = rgba[offset..][0..4].*;
        if (std.mem.eql(u8, &pixel, &previous)) {
            run += 1;
            if (run == 62 or offset + 4 == rgba.len) {
                try out.append(allocator, 0xc0 | (run - 1));
                run = 0;
            }
            continue;
        }
        if (run > 0) {
            try out.append(allocator, 0xc0 | (run - 1));
            run = 0;
        }
        try out.append(allocator, 0xff);
        try out.appendSlice(allocator, &pixel);
        previous = pixel;
    }
    const qoi_end_marker = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
    try out.appendSlice(allocator, &qoi_end_marker);
    return out.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Image {
    const end_marker = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
    if (data.len < 22 or !std.mem.eql(u8, data[0..4], "qoif") or data[12] != 4 or data[13] != 0) return error.InvalidQoi;
    const width = readU32(data[4..8]);
    const height = readU32(data[8..12]);
    if (width == 0 or height == 0) return error.InvalidQoi;
    const row_len = std.math.mul(usize, @as(usize, width), 4) catch return error.InvalidQoi;
    const len = std.math.mul(usize, row_len, @as(usize, height)) catch return error.InvalidQoi;
    const rgba = try allocator.alloc(u8, len);
    errdefer allocator.free(rgba);

    var pixel = [4]u8{ 0, 0, 0, 255 };
    var src: usize = 14;
    var dst: usize = 0;
    while (dst < len) {
        if (src >= data.len - 8) return error.InvalidQoi;
        const op = data[src];
        src += 1;
        if (op == 0xff) {
            if (src + 4 > data.len - end_marker.len) return error.InvalidQoi;
            pixel = data[src..][0..4].*;
            src += 4;
            @memcpy(rgba[dst..][0..4], &pixel);
            dst += 4;
        } else if (op & 0xc0 == 0xc0) {
            const count: usize = @as(usize, op & 0x3f) + 1;
            if (dst + count * 4 > len) return error.InvalidQoi;
            for (0..count) |_| {
                @memcpy(rgba[dst..][0..4], &pixel);
                dst += 4;
            }
        } else return error.InvalidQoi;
    }
    if (src + end_marker.len != data.len or !std.mem.eql(u8, data[src..], &end_marker)) return error.InvalidQoi;
    return .{ .width = width, .height = height, .rgba = rgba };
}

fn appendU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .big);
    try out.appendSlice(allocator, &bytes);
}

fn readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

