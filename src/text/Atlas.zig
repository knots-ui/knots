const std = @import("std");
const glyph = @import("glyph.zig");

width: u32,
height: u32,
bitmap: []u8,
cursor_x: u32,
cursor_y: u32,
shelf_h: u32,
dirty_min_y: u32,
dirty_max_y_excl: u32,
allocator: std.mem.Allocator,

const Atlas = @This();

pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Atlas {
    const bitmap = try allocator.alloc(u8, width * height);
    @memset(bitmap, 0);
    return .{
        .width = width,
        .height = height,
        .bitmap = bitmap,
        .cursor_x = 0,
        .cursor_y = 0,
        .shelf_h = 0,
        .dirty_min_y = 0,
        .dirty_max_y_excl = height,
        .allocator = allocator,
    };
}

pub fn isDirty(self: *const Atlas) bool {
    return self.dirty_min_y < self.dirty_max_y_excl;
}

pub fn markClean(self: *Atlas) void {
    self.dirty_min_y = self.height;
    self.dirty_max_y_excl = 0;
}

fn markDirtyRows(self: *Atlas, y0: u32, y1_excl: u32) void {
    if (y0 >= y1_excl) return;
    if (!self.isDirty()) {
        self.dirty_min_y = y0;
        self.dirty_max_y_excl = y1_excl;
    } else {
        self.dirty_min_y = @min(self.dirty_min_y, y0);
        self.dirty_max_y_excl = @max(self.dirty_max_y_excl, y1_excl);
    }
}

pub fn deinit(self: *Atlas) void {
    self.allocator.free(self.bitmap);
}

pub fn pack(self: *Atlas, bitmap: []const u8, w: u32, h: u32) !glyph.Rect {
    const padding = 1;

    if (self.cursor_x + w + padding > self.width) {
        self.cursor_y += self.shelf_h + padding;
        self.cursor_x = 0;
        self.shelf_h = 0;
    }

    if (self.cursor_y + h + padding > self.height) {
        return error.AtlasFull;
    }

    for (0..h) |row| {
        const src = bitmap[row * w .. row * w + w];
        const dst_start = (self.cursor_y + row) * self.width + self.cursor_x;
        @memcpy(self.bitmap[dst_start .. dst_start + w], src);
    }

    const rect = glyph.Rect{
        .u = @as(f32, @floatFromInt(self.cursor_x)) / @as(f32, @floatFromInt(self.width)),
        .v = @as(f32, @floatFromInt(self.cursor_y)) / @as(f32, @floatFromInt(self.height)),
        .uw = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(self.width)),
        .uh = @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(self.height)),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    };

    self.cursor_x += w + padding;
    self.shelf_h = @max(self.shelf_h, h);
    self.markDirtyRows(self.cursor_y, self.cursor_y + h);

    return rect;
}

pub fn flush(self: *Atlas) void {
    _ = self;
}
