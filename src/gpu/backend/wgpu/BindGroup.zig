const std = @import("std");
const wgpu = @import("wgpu");
const Context = @import("Context.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("Buffer.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const BindGroup = @This();

bind_group: wgpu.BindGroup,

pub const BufferBinding = struct {
    buffer: *const Buffer,
    offset: u64 = 0,
    size: u64 = 0,
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

pub fn create(_: std.mem.Allocator, ctx: *Context, desc: Desc) !BindGroup {
    const layout = desc.pipeline.bindGroupLayout(desc.layout_index);

    var entry_buf: [16]wgpu.BindGroup.Entry = undefined;
    if (desc.entries.len > entry_buf.len) return error.TooManyBindGroupEntries;
    for (desc.entries, 0..) |e, i| {
        var w: wgpu.BindGroup.Entry = .{ .binding = e.binding };
        switch (e.resource) {
            .buffer => |b| {
                w.buffer = b.buffer.buffer;
                w.offset = b.offset;
                w.size = if (b.size == 0) @intCast(b.buffer.size - @as(usize, @intCast(b.offset))) else b.size;
            },
            .read_only_storage_buffer => |b| {
                w.buffer = b.buffer.buffer;
                w.offset = b.offset;
                w.size = if (b.size == 0) @intCast(b.buffer.size - @as(usize, @intCast(b.offset))) else b.size;
            },
            .texture_view => |t| {
                w.texture_view = t.view;
            },
            .sampler => |s| {
                w.sampler = s.sampler;
            },
        }
        entry_buf[i] = w;
    }

    const bg = try ctx.device.createBindGroup(.{
        .label = desc.label,
        .layout = layout,
        .entries = entry_buf[0..desc.entries.len],
    });

    return .{
        .bind_group = bg,
    };
}

pub fn deinit(self: *BindGroup) void {
    self.bind_group.deinit();
}
