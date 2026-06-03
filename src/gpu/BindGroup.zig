const Buffer = @import("Buffer.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");
const Pipeline = @import("Pipeline.zig");

const BindGroup = @This();

pub const BufferBinding = struct {
    buffer: *const Buffer,
    offset: u64 = 0,
    size: u64 = 0, // 0 = whole buffer
};

pub const Entry = union(enum) {
    buffer: BufferBinding,
    read_only_storage_buffer: BufferBinding,
    texture_view: *const Texture,
    sampler: *const Sampler,
};

pub const BindingEntry = struct {
    binding: u32,
    resource: Entry,
};

pub const Desc = struct {
    label: []const u8 = "",
    pipeline: *const Pipeline,
    layout_index: u32,
    entries: []const BindingEntry,
};

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
};

pub inline fn deinit(self: *const BindGroup) void {
    self.vtable.deinit(self.ptr);
}
