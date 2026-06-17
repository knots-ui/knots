const std = @import("std");
const vk = @import("vk");
const CommonTexture = @import("gpu").Texture;

const Context = @import("Context.zig");

const NativeHandle = struct {
    image: vk.Image,
    image_view: vk.ImageView,
    format: vk.Format,
    width: u32,
    height: u32,
};

const Texture = @This();

pub const Format = CommonTexture.Format;
pub const Usage = CommonTexture.Usage;
pub const Desc = CommonTexture.Desc;

image: vk.Image,
memory: vk.DeviceMemory,
image_view: vk.ImageView,
ready: bool,
layout: vk.ImageLayout,
width: u32,
height: u32,
format: Format,
ctx: *Context,
staging_buffer: vk.Buffer = .null_handle,
staging_memory: vk.DeviceMemory = .null_handle,
staging_size: usize = 0,
upload_submission: ?Context.SingleTimeSubmission = null,
native_handle: NativeHandle,

pub fn create(_: std.mem.Allocator, ctx: *Context, desc: Desc) !Texture {
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

    return .{
        .image = image,
        .memory = memory,
        .image_view = image_view,
        .ready = false,
        .layout = .undefined,
        .width = desc.width,
        .height = desc.height,
        .format = desc.format,
        .ctx = ctx,
        .native_handle = .{
            .image = image,
            .image_view = image_view,
            .format = vk_format,
            .width = desc.width,
            .height = desc.height,
        },
    };
}

pub fn deinit(self: *Texture) void {
    self.finishUpload() catch {};
    if (self.staging_size != 0) {
        self.ctx.vkd.destroyBuffer(self.ctx.device, self.staging_buffer, null);
        self.ctx.vkd.freeMemory(self.ctx.device, self.staging_memory, null);
    }
    self.ctx.vkd.destroyImageView(self.ctx.device, self.image_view, null);
    self.ctx.vkd.destroyImage(self.ctx.device, self.image, null);
    self.ctx.vkd.freeMemory(self.ctx.device, self.memory, null);
}

fn ensureStaging(self: *Texture, len: usize) !void {
    if (len <= self.staging_size) return;
    const ctx = self.ctx;

    const new_buffer = try ctx.vkd.createBuffer(ctx.device, &.{
        .size = @intCast(len),
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    errdefer ctx.vkd.destroyBuffer(ctx.device, new_buffer, null);

    const mem_reqs = ctx.vkd.getBufferMemoryRequirements(ctx.device, new_buffer);
    const new_memory = try ctx.vkd.allocateMemory(ctx.device, &.{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try ctx.findMemoryType(mem_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }),
    }, null);
    errdefer ctx.vkd.freeMemory(ctx.device, new_memory, null);

    try ctx.vkd.bindBufferMemory(ctx.device, new_buffer, new_memory, 0);

    if (self.staging_size != 0) {
        ctx.vkd.destroyBuffer(ctx.device, self.staging_buffer, null);
        ctx.vkd.freeMemory(ctx.device, self.staging_memory, null);
    }
    self.staging_buffer = new_buffer;
    self.staging_memory = new_memory;
    self.staging_size = len;
}

fn finishUpload(self: *Texture) !void {
    const submission = self.upload_submission orelse return;
    try self.ctx.finishSingleTimeCommands(submission);
    self.upload_submission = null;
}

pub fn write(self: *Texture, data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) !void {
    const ctx = self.ctx;

    try self.finishUpload();
    try self.ensureStaging(len);

    const mapped: [*]u8 = @ptrCast(try ctx.vkd.mapMemory(ctx.device, self.staging_memory, 0, @intCast(len), .{}));
    @memcpy(mapped[0..len], data[0..len]);
    ctx.vkd.unmapMemory(ctx.device, self.staging_memory);

    const cmd = try ctx.beginSingleTimeCommands();
    const src_stage = if (self.layout == .undefined)
        vk.PipelineStageFlags{ .top_of_pipe_bit = true }
    else
        vk.PipelineStageFlags{ .fragment_shader_bit = true };
    const src_access = if (self.layout == .undefined)
        vk.AccessFlags{}
    else
        vk.AccessFlags{ .shader_read_bit = true };

    ctx.vkd.cmdPipelineBarrier(cmd, src_stage, .{ .transfer_bit = true }, .{}, null, null, &.{.{
        .src_access_mask = src_access,
        .dst_access_mask = .{ .transfer_write_bit = true },
        .old_layout = self.layout,
        .new_layout = .transfer_dst_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = self.image,
        .subresource_range = .{ .aspect_mask = .{ .color_bit = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
    }});

    const row_length: u32 = if (bytes_per_row) |bpr| bpr / bytesPerPixel(self.format) else 0;
    ctx.vkd.cmdCopyBufferToImage(cmd, self.staging_buffer, self.image, .transfer_dst_optimal, &.{.{
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

    self.upload_submission = try ctx.endSingleTimeCommands(cmd);
    self.ready = true;
    self.layout = .shader_read_only_optimal;
}

pub fn isReady(self: *const Texture) bool {
    return self.ready;
}

fn bytesPerPixel(format: Format) u32 {
    return switch (format) {
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .r8 => 1,
        .rgba32f, .rgba32u => 16,
    };
}

fn toVkFormat(format: Format) vk.Format {
    return switch (format) {
        .rgba8 => .r8g8b8a8_unorm,
        .rgba8_srgb => .r8g8b8a8_srgb,
        .bgra8 => .b8g8r8a8_unorm,
        .bgra8_srgb => .b8g8r8a8_srgb,
        .r8 => .r8_unorm,
        .rgba32f => .r32g32b32a32_sfloat,
        .rgba32u => .r32g32b32a32_uint,
    };
}

pub fn nativeHandle(self: *Texture) *anyopaque {
    self.native_handle = .{
        .image = self.image,
        .image_view = self.image_view,
        .format = toVkFormat(self.format),
        .width = self.width,
        .height = self.height,
    };
    return &self.native_handle;
}
