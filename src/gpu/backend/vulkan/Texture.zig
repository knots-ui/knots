const std = @import("std");
const vk = @import("vk");
const gpu = @import("gpu");
const Context = @import("Context.zig");
const Sampler = @import("Sampler.zig");

const NativeHandle = struct {
    image: vk.Image,
    image_view: vk.ImageView,
    format: vk.Format,
    width: u32,
    height: u32,
};

const Texture = @This();

allocator: std.mem.Allocator,
image: vk.Image,
memory: vk.DeviceMemory,
image_view: vk.ImageView,
descriptor_set: vk.DescriptorSet,
descriptor_written: bool,
sampler_bound: bool,
width: u32,
height: u32,
format: gpu.Texture.Format,
ctx: *Context,
_native_handle: NativeHandle = undefined,

pub fn create(allocator: std.mem.Allocator, ctx: *Context, desc: gpu.Texture.Desc) !gpu.Texture {
    const vk_format = toVkFormat(desc.format);

    const image = try ctx.vkd.createImage(ctx.device, &.{
        .image_type = .@"2d",
        .format = vk_format,
        .extent = .{ .width = desc.width, .height = desc.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{
            .transfer_dst_bit = desc.usage.copy_dst,
            .transfer_src_bit = desc.usage.copy_src,
            .sampled_bit = desc.usage.texture_binding,
            .color_attachment_bit = desc.usage.render_attachment,
        },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);
    errdefer ctx.vkd.destroyImage(ctx.device, image, null);

    const mem_reqs = ctx.vkd.getImageMemoryRequirements(ctx.device, image);
    const memory = try ctx.vkd.allocateMemory(ctx.device, &.{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try ctx.findMemoryType(mem_reqs.memory_type_bits, .{ .device_local_bit = true }),
    }, null);
    errdefer ctx.vkd.freeMemory(ctx.device, memory, null);

    try ctx.vkd.bindImageMemory(ctx.device, image, memory, 0);

    const image_view = try ctx.vkd.createImageView(ctx.device, &.{
        .image = image,
        .view_type = .@"2d",
        .format = vk_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
    }, null);
    errdefer ctx.vkd.destroyImageView(ctx.device, image_view, null);

    const descriptor_set = try ctx.allocateDescriptorSet(ctx.texture_descriptor_set_layout);

    if (desc.sampler) |s| {
        const vk_sampler: *Sampler = @ptrCast(@alignCast(s.ptr));
        ctx.vkd.updateDescriptorSets(ctx.device, &.{.{
            .dst_set = descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = &[_]vk.DescriptorImageInfo{.{
                .sampler = vk_sampler.sampler,
                .image_view = image_view,
                .image_layout = .shader_read_only_optimal,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }}, null);
    }

    const self = try allocator.create(Texture);
    self.* = .{
        .allocator = allocator,
        .image = image,
        .memory = memory,
        .image_view = image_view,
        .descriptor_set = descriptor_set,
        .descriptor_written = false,
        .sampler_bound = desc.sampler != null,
        .width = desc.width,
        .height = desc.height,
        .format = desc.format,
        .ctx = ctx,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

pub fn writeDescriptor(self: *Texture, sampler: *Sampler) void {
    self.ctx.vkd.updateDescriptorSets(self.ctx.device, &.{.{
        .dst_set = self.descriptor_set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = &[_]vk.DescriptorImageInfo{.{
            .sampler = sampler.sampler,
            .image_view = self.image_view,
            .image_layout = .shader_read_only_optimal,
        }},
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    }}, null);
}

const vtable = gpu.Texture.VTable{
    .deinit = &deinit,
    .write = &write,
    .is_ready = &isReady,
    .nativeHandle = &nativeHandle,
};

fn deinit(ptr: *anyopaque) void {
    const self: *Texture = @ptrCast(@alignCast(ptr));
    self.ctx.vkd.destroyImageView(self.ctx.device, self.image_view, null);
    self.ctx.vkd.destroyImage(self.ctx.device, self.image, null);
    self.ctx.vkd.freeMemory(self.ctx.device, self.memory, null);
    self.allocator.destroy(self);
}

fn write(ptr: *anyopaque, data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) !void {
    const self: *Texture = @ptrCast(@alignCast(ptr));
    try writeImpl(self, data, len, x, y, width, height, bytes_per_row);
}

fn writeImpl(self: *Texture, data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) !void {
    const ctx = self.ctx;

    const staging_buffer = try ctx.vkd.createBuffer(ctx.device, &.{
        .size = @intCast(len),
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer ctx.vkd.destroyBuffer(ctx.device, staging_buffer, null);

    const mem_reqs = ctx.vkd.getBufferMemoryRequirements(ctx.device, staging_buffer);
    const staging_memory = try ctx.vkd.allocateMemory(ctx.device, &.{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try ctx.findMemoryType(mem_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }),
    }, null);
    defer ctx.vkd.freeMemory(ctx.device, staging_memory, null);

    try ctx.vkd.bindBufferMemory(ctx.device, staging_buffer, staging_memory, 0);
    const mapped: [*]u8 = @ptrCast(try ctx.vkd.mapMemory(ctx.device, staging_memory, 0, @intCast(len), .{}));
    @memcpy(mapped[0..len], data[0..len]);
    ctx.vkd.unmapMemory(ctx.device, staging_memory);

    const cmd = try ctx.beginSingleTimeCommands();

    ctx.vkd.cmdPipelineBarrier(cmd, .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true }, .{}, null, null, &.{.{
        .src_access_mask = .{},
        .dst_access_mask = .{ .transfer_write_bit = true },
        .old_layout = .undefined,
        .new_layout = .transfer_dst_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.image,
        .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
    }});

    const row_length: u32 = if (bytes_per_row) |bpr| bpr / bytesPerPixel(self.format) else 0;
    ctx.vkd.cmdCopyBufferToImage(cmd, staging_buffer, self.image, .transfer_dst_optimal, &.{.{
        .buffer_offset = 0,
        .buffer_row_length = row_length,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = @intCast(x), .y = @intCast(y), .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    }});

    ctx.vkd.cmdPipelineBarrier(cmd, .{ .transfer_bit = true }, .{ .fragment_shader_bit = true }, .{}, null, null, &.{.{
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
        .old_layout = .transfer_dst_optimal,
        .new_layout = .shader_read_only_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.image,
        .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
    }});

    try ctx.endSingleTimeCommands(cmd);
    self.descriptor_written = true;
}

fn isReady(ptr: *anyopaque) bool {
    const self: *Texture = @ptrCast(@alignCast(ptr));
    return self.descriptor_written;
}

fn bytesPerPixel(format: gpu.Texture.Format) u32 {
    return switch (format) {
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .r8 => 1,
    };
}

fn toVkFormat(format: gpu.Texture.Format) vk.Format {
    return switch (format) {
        .rgba8 => .r8g8b8a8_unorm,
        .rgba8_srgb => .r8g8b8a8_srgb,
        .bgra8 => .b8g8r8a8_unorm,
        .bgra8_srgb => .b8g8r8a8_srgb,
        .r8 => .r8_unorm,
    };
}

fn nativeHandle(ptr: *anyopaque) *anyopaque {
    const self: *Texture = @ptrCast(@alignCast(ptr));
    self._native_handle = .{
        .image = self.image,
        .image_view = self.image_view,
        .format = toVkFormat(self.format),
        .width = self.width,
        .height = self.height,
    };
    return &self._native_handle;
}
