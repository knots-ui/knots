const std = @import("std");
const vk = @import("vk");
const Context = @import("Context.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("Buffer.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const BindGroup = @This();

ctx: *Context,
descriptor_set: vk.DescriptorSet,
descriptor_pool: vk.DescriptorPool,

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
    const layout = desc.pipeline.descriptorSetLayout(desc.layout_index);

    const alloc_result = try ctx.allocateDescriptorSetWithPool(layout);

    var writes_buf: [16]vk.WriteDescriptorSet = undefined;
    var buf_info_buf: [16]vk.DescriptorBufferInfo = undefined;
    var img_info_buf: [16]vk.DescriptorImageInfo = undefined;
    if (desc.entries.len > writes_buf.len) return error.TooManyBindGroupEntries;

    for (desc.entries, 0..) |e, i| {
        switch (e.resource) {
            .buffer => |b| {
                buf_info_buf[i] = .{
                    .buffer = b.buffer.buffer,
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
                buf_info_buf[i] = .{
                    .buffer = b.buffer.buffer,
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
                img_info_buf[i] = .{
                    .sampler = .null_handle,
                    .image_view = t.image_view,
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
                img_info_buf[i] = .{
                    .sampler = s.sampler,
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

    return .{
        .ctx = ctx,
        .descriptor_set = alloc_result.set,
        .descriptor_pool = alloc_result.pool,
    };
}

pub fn deinit(self: *BindGroup) void {
    self.ctx.vkd.freeDescriptorSets(self.ctx.device, self.descriptor_pool, &.{self.descriptor_set}) catch {};
}
