const Sampler = @import("Sampler.zig");

const Texture = @This();

pub const Format = enum { rgba8, rgba8_srgb, bgra8, bgra8_srgb, r8, rgba32f, rgba32u };

pub const Usage = struct {
    texture_binding: bool = false,
    copy_dst: bool = false,
    copy_src: bool = false,
    render_attachment: bool = false,
};

pub const Desc = struct {
    width: u32,
    height: u32,
    format: Format,
    usage: Usage,
    label: []const u8 = "",
    sampler: ?*const Sampler = null,
};

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    write: *const fn (ptr: *anyopaque, data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) anyerror!void,
    is_ready: *const fn (ptr: *anyopaque) bool,
    nativeHandle: *const fn (ptr: *anyopaque) *anyopaque,
};

pub inline fn deinit(self: *const Texture) void {
    self.vtable.deinit(self.ptr);
}

pub inline fn write(self: *const Texture, data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) !void {
    return self.vtable.write(self.ptr, data, len, x, y, width, height, bytes_per_row);
}

pub inline fn isReady(self: *const Texture) bool {
    return self.vtable.is_ready(self.ptr);
}

pub inline fn nativeHandle(self: *const Texture) *anyopaque {
    return self.vtable.nativeHandle(self.ptr);
}
