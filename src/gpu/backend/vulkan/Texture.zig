const std = @import("std");
const vk = @import("vk");
const CommonTexture = @import("gpu").Texture;

const Device = @import("Device.zig");
const MemoryAllocator = @import("MemoryAllocator.zig");

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
allocation: MemoryAllocator.Allocation,
image_view: vk.ImageView,
ready: bool,
layout: vk.ImageLayout,
width: u32,
height: u32,
format: Format,
device: *Device,
native_handle: NativeHandle,

pub fn create(device: *Device, desc: Desc) !Texture {
    std.debug.assert(desc.width != 0 and desc.height != 0);
    if (desc.format == .depth24_plus) return error.UnsupportedTextureFormat;
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

    var dedicated = vk.MemoryDedicatedRequirements{
        .prefers_dedicated_allocation = undefined,
        .requires_dedicated_allocation = undefined,
    };
    var requirements = vk.MemoryRequirements2{ .p_next = &dedicated, .memory_requirements = undefined };
    device.vkd.getImageMemoryRequirements2(device.device, &.{ .image = image }, &requirements);
    const allocation = try device.memory_allocator.allocate(
        requirements.memory_requirements,
        dedicated,
        .{ .image = image },
        .optimal,
        .{ .device_local = true },
        .{},
    );
    errdefer device.memory_allocator.free(allocation);

    try device.vkd.bindImageMemory(device.device, image, allocation.memory, allocation.offset);

    const image_view = try device.vkd.createImageView(device.device, &.{
        .image = image,
        .view_type = .@"2d",
        .format = vk_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
    }, null);
    errdefer device.vkd.destroyImageView(device.device, image_view, null);
    device.setDebugName(.image, @intFromEnum(image), desc.label);
    device.setDebugName(.image_view, @intFromEnum(image_view), desc.label);

    return .{
        .image = image,
        .allocation = allocation,
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
    self.device.cancelTextureUploads(self.image);
    self.device.vkd.destroyImageView(self.device.device, self.image_view, null);
    self.device.vkd.destroyImage(self.device.device, self.image, null);
    self.device.memory_allocator.free(self.allocation);
}

pub fn write(self: *Texture, data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) !void {
    std.debug.assert(width != 0 and height != 0);
    std.debug.assert(x <= self.width and y <= self.height);
    std.debug.assert(width <= self.width - x and height <= self.height - y);
    const pixel_size = bytesPerPixel(self.format);
    const packed_row = std.math.mul(u32, width, pixel_size) catch {
        std.debug.assert(false);
        unreachable;
    };
    const stride = bytes_per_row orelse packed_row;
    std.debug.assert(stride >= packed_row and stride % pixel_size == 0);
    const required = std.math.add(
        usize,
        std.math.mul(usize, @as(usize, height - 1), @as(usize, stride)) catch {
            std.debug.assert(false);
            unreachable;
        },
        @as(usize, packed_row),
    ) catch {
        std.debug.assert(false);
        unreachable;
    };
    std.debug.assert(len >= required);

    try self.device.queueTextureUpload(self.image, self.layout, data[0..required], pixel_size, x, y, width, height, bytes_per_row);
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
        .depth24_plus => 4,
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
        .depth24_plus => .d32_sfloat,
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
