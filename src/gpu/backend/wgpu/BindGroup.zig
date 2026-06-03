const std = @import("std");
const wgpu = @import("wgpu");
const gpu = @import("gpu");
const Context = @import("Context.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("Buffer.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const BindGroup = @This();

allocator: std.mem.Allocator,
bind_group: wgpu.BindGroup,

pub fn create(allocator: std.mem.Allocator, ctx: *Context, desc: gpu.BindGroup.Desc) !gpu.BindGroup {
    const wgpu_pipeline: *Pipeline = @ptrCast(@alignCast(desc.pipeline.ptr));
    const layout = wgpu_pipeline.bindGroupLayout(desc.layout_index);

    var entry_buf: [16]wgpu.BindGroup.Entry = undefined;
    if (desc.entries.len > entry_buf.len) return error.TooManyBindGroupEntries;
    for (desc.entries, 0..) |e, i| {
        var w: wgpu.BindGroup.Entry = .{ .binding = e.binding };
        switch (e.resource) {
            .buffer => |b| {
                const wbuf: *Buffer = @ptrCast(@alignCast(b.buffer.ptr));
                w.buffer = wbuf.buffer;
                w.offset = b.offset;
                w.size = if (b.size == 0) wbuf.size - b.offset else b.size;
            },
            .read_only_storage_buffer => |b| {
                const wbuf: *Buffer = @ptrCast(@alignCast(b.buffer.ptr));
                w.buffer = wbuf.buffer;
                w.offset = b.offset;
                w.size = if (b.size == 0) wbuf.size - b.offset else b.size;
            },
            .texture_view => |t| {
                const wtex: *Texture = @ptrCast(@alignCast(t.ptr));
                w.texture_view = wtex.view;
            },
            .sampler => |s| {
                const wsamp: *Sampler = @ptrCast(@alignCast(s.ptr));
                w.sampler = wsamp.sampler;
            },
        }
        entry_buf[i] = w;
    }

    const bg = try ctx.device.createBindGroup(.{
        .label = desc.label,
        .layout = layout,
        .entries = entry_buf[0..desc.entries.len],
    });

    const self = try allocator.create(BindGroup);
    self.* = .{
        .allocator = allocator,
        .bind_group = bg,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = gpu.BindGroup.VTable{
    .deinit = &deinit,
};

fn deinit(ptr: *anyopaque) void {
    const self: *BindGroup = @ptrCast(@alignCast(ptr));
    self.bind_group.deinit();
    self.allocator.destroy(self);
}
