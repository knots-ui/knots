const std = @import("std");
const vk = @import("vk");
const gpu = @import("gpu");
const Context = @import("Context.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("Buffer.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const BindGroup = @This();

allocator: std.mem.Allocator,
ctx: *Context,
descriptor_set: vk.DescriptorSet,
descriptor_pool: vk.DescriptorPool,

pub fn create(allocator: std.mem.Allocator, ctx: *Context, desc: gpu.BindGroup.Desc) !gpu.BindGroup {
    const vk_pipeline: *Pipeline = @ptrCast(@alignCast(desc.pipeline.ptr));
    const layout = vk_pipeline.descriptorSetLayout(desc.layout_index);

    const alloc_result = try ctx.allocateDescriptorSetWithPool(layout);

    var writes_buf: [16]vk.WriteDescriptorSet = undefined;
    var buf_info_buf: [16]vk.DescriptorBufferInfo = undefined;
    var img_info_buf: [16]vk.DescriptorImageInfo = undefined;
    if (desc.entries.len > writes_buf.len) return error.TooManyBindGroupEntries;

    for (desc.entries, 0..) |e, i| {
        switch (e.resource) {
            .buffer => |b| {
                const vbuf: *Buffer = @ptrCast(@alignCast(b.buffer.ptr));
                buf_info_buf[i] = .{
                    .buffer = vbuf.buffer,
                    .offset = b.offset,
                    .range = if (b.size == 0) vk.WHOLE_SIZE else b.size,
                };
                writes_buf[i] = .{
                    .dst_set = alloc_result.set,
                    .dst_binding = e.binding,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .uniform_buffer,
                    .p_buffer_info = buf_info_buf[i .. i + 1].ptr,
                    .p_image_info = undefined,
                    .p_texel_buffer_view = undefined,
                };
            },
            .read_only_storage_buffer => |b| {
                const vbuf: *Buffer = @ptrCast(@alignCast(b.buffer.ptr));
                buf_info_buf[i] = .{
                    .buffer = vbuf.buffer,
                    .offset = b.offset,
                    .range = if (b.size == 0) vk.WHOLE_SIZE else b.size,
                };
                writes_buf[i] = .{
                    .dst_set = alloc_result.set,
                    .dst_binding = e.binding,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .storage_buffer,
                    .p_buffer_info = buf_info_buf[i .. i + 1].ptr,
                    .p_image_info = undefined,
                    .p_texel_buffer_view = undefined,
                };
            },
            .texture_view => |t| {
                const vtex: *Texture = @ptrCast(@alignCast(t.ptr));
                img_info_buf[i] = .{
                    .sampler = .null_handle,
                    .image_view = vtex.image_view,
                    .image_layout = .shader_read_only_optimal,
                };
                writes_buf[i] = .{
                    .dst_set = alloc_result.set,
                    .dst_binding = e.binding,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .sampled_image,
                    .p_image_info = img_info_buf[i .. i + 1].ptr,
                    .p_buffer_info = undefined,
                    .p_texel_buffer_view = undefined,
                };
            },
            .sampler => |s| {
                const vsamp: *Sampler = @ptrCast(@alignCast(s.ptr));
                img_info_buf[i] = .{
                    .sampler = vsamp.sampler,
                    .image_view = .null_handle,
                    .image_layout = .undefined,
                };
                writes_buf[i] = .{
                    .dst_set = alloc_result.set,
                    .dst_binding = e.binding,
                    .dst_array_element = 0,
                    .descriptor_count = 1,
                    .descriptor_type = .sampler,
                    .p_image_info = img_info_buf[i .. i + 1].ptr,
                    .p_buffer_info = undefined,
                    .p_texel_buffer_view = undefined,
                };
            },
        }
    }

    ctx.vkd.updateDescriptorSets(ctx.device, writes_buf[0..desc.entries.len], null);

    const self = try allocator.create(BindGroup);
    self.* = .{
        .allocator = allocator,
        .ctx = ctx,
        .descriptor_set = alloc_result.set,
        .descriptor_pool = alloc_result.pool,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = gpu.BindGroup.VTable{
    .deinit = &deinit,
};

fn deinit(ptr: *anyopaque) void {
    const self: *BindGroup = @ptrCast(@alignCast(ptr));
    self.ctx.vkd.freeDescriptorSets(self.ctx.device, self.descriptor_pool, &.{self.descriptor_set}) catch {};
    self.allocator.destroy(self);
}
