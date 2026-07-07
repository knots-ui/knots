const vk = @import("vk");
const CommonTexture = @import("gpu").Texture;

const Device = @import("Device.zig");

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
device: *Device,
staging_buffer: vk.Buffer = .null_handle,
staging_memory: vk.DeviceMemory = .null_handle,
staging_size: usize = 0,
upload_submission: ?Device.SingleTimeSubmission = null,
native_handle: NativeHandle,

pub fn create(device: *Device, desc: Desc) !Texture {
    const vk_format = toVkFormat(desc.format);

    const image = try device.vkd.createImage(device.device, &.{
        .image_type = .@"2d",
        .format = vk_format,
        .extent = .{ .width = desc.width, .height = desc.height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1" = true },
        .tiling = .optimal,
        .usage = .{
            .transfer_dst = desc.usage.copy_dst,
            .transfer_src = desc.usage.copy_src,
            .sampled = desc.usage.texture_binding,
            .color_attachment = desc.usage.render_attachment,
        },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);
    errdefer device.vkd.destroyImage(device.device, image, null);

    const mem_reqs = device.vkd.getImageMemoryRequirements(device.device, image);
    const memory = try device.vkd.allocateMemory(device.device, &.{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try device.findMemoryType(mem_reqs.memory_type_bits, .{ .device_local = true }),
    }, null);
    errdefer device.vkd.freeMemory(device.device, memory, null);

    try device.vkd.bindImageMemory(device.device, image, memory, 0);

    const image_view = try device.vkd.createImageView(device.device, &.{
        .image = image,
        .view_type = .@"2d",
        .format = vk_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
    }, null);
    errdefer device.vkd.destroyImageView(device.device, image_view, null);

    return .{
        .image = image,
        .memory = memory,
        .image_view = image_view,
        .ready = false,
        .layout = .undefined,
        .width = desc.width,
        .height = desc.height,
        .format = desc.format,
        .device = device,
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
        self.device.vkd.destroyBuffer(self.device.device, self.staging_buffer, null);
        self.device.vkd.freeMemory(self.device.device, self.staging_memory, null);
    }
    self.device.vkd.destroyImageView(self.device.device, self.image_view, null);
    self.device.vkd.destroyImage(self.device.device, self.image, null);
    self.device.vkd.freeMemory(self.device.device, self.memory, null);
}

fn ensureStaging(self: *Texture, len: usize) !void {
    if (len <= self.staging_size) return;
    const device = self.device;

    const new_buffer = try device.vkd.createBuffer(device.device, &.{
        .size = @intCast(len),
        .usage = .{ .transfer_src = true },
        .sharing_mode = .exclusive,
    }, null);
    errdefer device.vkd.destroyBuffer(device.device, new_buffer, null);

    const mem_reqs = device.vkd.getBufferMemoryRequirements(device.device, new_buffer);
    const new_memory = try device.vkd.allocateMemory(device.device, &.{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try device.findMemoryType(mem_reqs.memory_type_bits, .{ .host_visible = true, .host_coherent = true }),
    }, null);
    errdefer device.vkd.freeMemory(device.device, new_memory, null);

    try device.vkd.bindBufferMemory(device.device, new_buffer, new_memory, 0);

    if (self.staging_size != 0) {
        device.vkd.destroyBuffer(device.device, self.staging_buffer, null);
        device.vkd.freeMemory(device.device, self.staging_memory, null);
    }
    self.staging_buffer = new_buffer;
    self.staging_memory = new_memory;
    self.staging_size = len;
}

fn finishUpload(self: *Texture) !void {
    const submission = self.upload_submission orelse return;
    try self.device.finishSingleTimeCommands(submission);
    self.upload_submission = null;
}

pub fn write(self: *Texture, data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) !void {
    const device = self.device;

    try self.finishUpload();
    try self.ensureStaging(len);

    const mapped: [*]u8 = @ptrCast(try device.vkd.mapMemory(device.device, self.staging_memory, 0, @intCast(len), .{}));
    @memcpy(mapped[0..len], data[0..len]);
    device.vkd.unmapMemory(device.device, self.staging_memory);

    const cmd = try device.beginSingleTimeCommands();
    device.vkd.cmdPipelineBarrier2(cmd, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[_]vk.ImageMemoryBarrier2{.{
            .src_stage_mask = if (self.layout == .undefined) .{} else .{ .fragment_shader = true },
            .src_access_mask = if (self.layout == .undefined) .{} else .{ .shader_sampled_read = true },
            .dst_stage_mask = .{ .all_transfer = true },
            .dst_access_mask = .{ .transfer_write = true },
            .old_layout = self.layout,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        }},
    });

    const row_length: u32 = if (bytes_per_row) |bpr| bpr / bytesPerPixel(self.format) else 0;
    device.vkd.cmdCopyBufferToImage(cmd, self.staging_buffer, self.image, .transfer_dst_optimal, &.{.{
        .buffer_offset = 0,
        .buffer_row_length = row_length,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = @intCast(x), .y = @intCast(y), .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    }});

    device.vkd.cmdPipelineBarrier2(cmd, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[_]vk.ImageMemoryBarrier2{.{
            .src_stage_mask = .{ .all_transfer = true },
            .src_access_mask = .{ .transfer_write = true },
            .dst_stage_mask = .{ .fragment_shader = true },
            .dst_access_mask = .{ .shader_sampled_read = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        }},
    });

    self.upload_submission = try device.endSingleTimeCommands(cmd);
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

pub fn toVkFormat(format: Format) vk.Format {
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
