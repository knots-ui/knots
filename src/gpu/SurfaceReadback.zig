const std = @import("std");
const Texture = @import("Texture.zig");

const SurfaceReadback = @This();

pub const Error = error{
    SurfaceReadbackUnsupported,
    SurfaceReadbackUnavailable,
    SurfaceReadbackTooLarge,
    SurfaceReadbackFailed,
};

allocator: std.mem.Allocator,
width: u32,
height: u32,
format: Texture.Format,
bytes_per_row: usize,
bytes: []u8,

pub fn deinit(self: *SurfaceReadback) void {
    self.allocator.free(self.bytes);
}

pub fn bytesPerPixel(format: Texture.Format) usize {
    return switch (format) {
        .r8 => 1,
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .rgba32f, .rgba32u => 16,
    };
}
