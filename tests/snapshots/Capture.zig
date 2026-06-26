const std = @import("std");
const gpu = @import("gpu");

pub const Frame = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.rgba);
    }
};

pub fn fromReadback(allocator: std.mem.Allocator, readback: gpu.SurfaceReadback) !Frame {
    const row_bytes = std.math.mul(usize, @as(usize, readback.width), 4) catch return error.CaptureTooLarge;
    if (readback.bytes_per_row < row_bytes) return error.InvalidCaptureData;
    const required_source = if (readback.height == 0)
        0
    else
        std.math.add(
            usize,
            std.math.mul(usize, @as(usize, readback.height - 1), readback.bytes_per_row) catch return error.CaptureTooLarge,
            row_bytes,
        ) catch return error.CaptureTooLarge;
    if (readback.bytes.len < required_source) return error.InvalidCaptureData;

    const bgra = switch (readback.format) {
        .bgra8, .bgra8_srgb => true,
        .rgba8, .rgba8_srgb => false,
        else => return error.UnsupportedCaptureFormat,
    };
    const rgba = try allocator.alloc(u8, std.math.mul(usize, row_bytes, @as(usize, readback.height)) catch return error.CaptureTooLarge);
    errdefer allocator.free(rgba);
    for (0..@as(usize, readback.height)) |y| {
        const src = readback.bytes[y * readback.bytes_per_row ..][0..row_bytes];
        const dst = rgba[y * row_bytes ..][0..row_bytes];
        if (bgra) {
            var x: usize = 0;
            while (x < row_bytes) : (x += 4) {
                dst[x..][0..4].* = .{ src[x + 2], src[x + 1], src[x], src[x + 3] };
            }
        } else {
            @memcpy(dst, src);
        }
    }
    return .{ .allocator = allocator, .width = readback.width, .height = readback.height, .rgba = rgba };
}
