const std = @import("std");
const vk = @import("vk");
const gpu = @import("gpu");

const Device = @import("Device.zig");

const Surface = @This();

const SwapchainInfo = struct {
    swapchain: vk.SwapchainKHR,
    format: vk.Format,
    color_space: vk.ColorSpaceKHR,
    extent: vk.Extent2D,
    is_srgb: bool,
    copy_src: bool,
    present_modes: gpu.Context.PresentModes,
};

allocator: std.mem.Allocator,
device: *Device,
surface: vk.SurfaceKHR,
swapchain: vk.SwapchainKHR,
swapchain_images: []vk.Image,
swapchain_views: []vk.ImageView,
swapchain_format: vk.Format,
swapchain_color_space: vk.ColorSpaceKHR,
swapchain_is_srgb: bool,
swapchain_copy_src: bool,
swapchain_extent: vk.Extent2D,
cfg: gpu.Context.Config,
present_modes: gpu.Context.PresentModes,

pub fn init(device: *Device, window_handle: gpu.Context.WindowHandle, cfg: gpu.Context.Config) !Surface {
    const allocator = device.allocator;
    const surface = try device.createSurfaceHandle(window_handle);
    errdefer device.vki.destroySurfaceKHR(device.instance, surface, null);

    if ((try device.vki.getPhysicalDeviceSurfaceSupportKHR(device.physical_device, device.queue_family, surface)) != .true)
        return error.NoCompatibleSurface;

    const required_format: Device.SurfaceFormat = .{
        .format = device.surface_format,
        .color_space = device.surface_color_space,
    };
    const sc = try createSwapchain(device, surface, cfg.window_width, cfg.window_height, .null_handle, required_format, cfg);
    errdefer device.vkd.destroySwapchainKHR(device.device, sc.swapchain, null);

    const images = try getSwapchainImages(allocator, device, sc.swapchain);
    errdefer allocator.free(images);

    const views = try createImageViews(allocator, device, images, sc.format);
    errdefer {
        for (views) |v| device.vkd.destroyImageView(device.device, v, null);
        allocator.free(views);
    }

    return .{
        .allocator = allocator,
        .device = device,
        .surface = surface,
        .swapchain = sc.swapchain,
        .swapchain_images = images,
        .swapchain_views = views,
        .swapchain_format = sc.format,
        .swapchain_color_space = sc.color_space,
        .swapchain_is_srgb = sc.is_srgb,
        .swapchain_copy_src = sc.copy_src,
        .swapchain_extent = sc.extent,
        .cfg = cfg,
        .present_modes = sc.present_modes,
    };
}

pub fn deinit(self: *Surface) void {
    const device = self.device;
    for (self.swapchain_views) |v| device.vkd.destroyImageView(device.device, v, null);
    self.allocator.free(self.swapchain_views);
    self.allocator.free(self.swapchain_images);
    device.vkd.destroySwapchainKHR(device.device, self.swapchain, null);
    device.vki.destroySurfaceKHR(device.instance, self.surface, null);
}

pub fn resize(self: *Surface, width: u32, height: u32) !void {
    try self.recreateSwapchain(width, height);
    self.cfg.window_width = width;
    self.cfg.window_height = height;
}

pub fn reconfigure(self: *Surface, cfg: gpu.Context.Config) !void {
    const old_cfg = self.cfg;
    self.cfg = cfg;
    self.recreateSwapchain(cfg.window_width, cfg.window_height) catch |err| {
        self.cfg = old_cfg;
        return err;
    };
}

pub fn supportedPresentModes(self: *const Surface) gpu.Context.PresentModes {
    return self.present_modes;
}

pub fn getFormat(self: *const Surface) gpu.Texture.Format {
    return Device.formatFromVk(self.swapchain_format);
}

pub fn recreateSwapchain(self: *Surface, width: u32, height: u32) !void {
    const device = self.device;
    const old_swapchain = self.swapchain;
    const required_format: Device.SurfaceFormat = .{
        .format = self.swapchain_format,
        .color_space = self.swapchain_color_space,
    };
    const sc = try createSwapchain(device, self.surface, width, height, old_swapchain, required_format, self.cfg);
    errdefer device.vkd.destroySwapchainKHR(device.device, sc.swapchain, null);

    const new_images = try getSwapchainImages(self.allocator, device, sc.swapchain);
    errdefer self.allocator.free(new_images);

    const new_views = try createImageViews(self.allocator, device, new_images, sc.format);
    errdefer {
        for (new_views) |v| device.vkd.destroyImageView(device.device, v, null);
        self.allocator.free(new_views);
    }

    for (self.swapchain_views) |v| device.vkd.destroyImageView(device.device, v, null);
    self.allocator.free(self.swapchain_views);
    self.allocator.free(self.swapchain_images);
    device.vkd.destroySwapchainKHR(device.device, old_swapchain, null);

    self.swapchain = sc.swapchain;
    self.swapchain_images = new_images;
    self.swapchain_views = new_views;
    self.swapchain_format = sc.format;
    self.swapchain_color_space = sc.color_space;
    self.swapchain_is_srgb = sc.is_srgb;
    self.swapchain_copy_src = sc.copy_src;
    self.swapchain_extent = sc.extent;
    self.present_modes = sc.present_modes;
}

fn createImageViews(allocator: std.mem.Allocator, device: *Device, images: []vk.Image, format: vk.Format) ![]vk.ImageView {
    const views = try allocator.alloc(vk.ImageView, images.len);
    var created: usize = 0;
    errdefer {
        for (views[0..created]) |v| device.vkd.destroyImageView(device.device, v, null);
        allocator.free(views);
    }

    for (images, views) |img, *view| {
        view.* = try device.vkd.createImageView(device.device, &.{
            .image = img,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        created += 1;
    }
    return views;
}

fn createSwapchain(
    device: *Device,
    surface: vk.SurfaceKHR,
    width: u32,
    height: u32,
    old_swapchain: vk.SwapchainKHR,
    required_format: Device.SurfaceFormat,
    cfg: gpu.Context.Config,
) !SwapchainInfo {
    const caps = try device.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(device.physical_device, surface);
    const copy_src = caps.supported_usage_flags.transfer_src;
    var format_count: u32 = 0;
    _ = try device.vki.getPhysicalDeviceSurfaceFormatsKHR(device.physical_device, surface, &format_count, null);
    var formats_buf: [32]vk.SurfaceFormatKHR = undefined;
    if (format_count > 32) format_count = 32;
    _ = try device.vki.getPhysicalDeviceSurfaceFormatsKHR(device.physical_device, surface, &format_count, &formats_buf);
    if (format_count == 0) return error.NoSurfaceFormatFound;

    const cf = blk: {
        for (formats_buf[0..format_count]) |f| {
            if (f.format == required_format.format and f.color_space == required_format.color_space) break :blk f;
        }
        return error.SurfaceFormatMismatch;
    };
    const extent = if (caps.current_extent.width != 0xFFFFFFFF) caps.current_extent else vk.Extent2D{
        .width = std.math.clamp(width, caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(height, caps.min_image_extent.height, caps.max_image_extent.height),
    };
    if (extent.width == 0 or extent.height == 0) return error.SurfaceUnavailable;

    const present_modes = try queryPresentModes(device, surface);
    const present_mode = choosePresentMode(present_modes, cfg.present_mode) orelse return error.UnsupportedPresentMode;
    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0 and image_count > caps.max_image_count) image_count = caps.max_image_count;
    const swapchain = try device.vkd.createSwapchainKHR(device.device, &.{
        .surface = surface,
        .min_image_count = image_count,
        .image_format = cf.format,
        .image_color_space = cf.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment = true, .transfer_src = copy_src },
        .image_sharing_mode = .exclusive,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_khr = true },
        .present_mode = present_mode,
        .clipped = .true,
        .old_swapchain = old_swapchain,
    }, null);
    return .{
        .swapchain = swapchain,
        .format = cf.format,
        .color_space = cf.color_space,
        .extent = extent,
        .is_srgb = isSrgbFormat(cf.format),
        .copy_src = copy_src,
        .present_modes = present_modes,
    };
}

fn choosePresentMode(modes: gpu.Context.PresentModes, requested: gpu.Context.PresentMode) ?vk.PresentModeKHR {
    if (!modes.contains(requested)) return null;
    return switch (requested) {
        .fifo => .fifo_khr,
        .fifo_relaxed => .fifo_relaxed_khr,
        .immediate => .immediate_khr,
        .mailbox => .mailbox_khr,
    };
}

fn queryPresentModes(device: *Device, surface: vk.SurfaceKHR) !gpu.Context.PresentModes {
    var modes = gpu.Context.PresentModes.empty;
    var count: u32 = 0;
    _ = try device.vki.getPhysicalDeviceSurfacePresentModesKHR(device.physical_device, surface, &count, null);
    var modes_buf: [16]vk.PresentModeKHR = undefined;
    if (count > modes_buf.len) count = @intCast(modes_buf.len);
    _ = try device.vki.getPhysicalDeviceSurfacePresentModesKHR(device.physical_device, surface, &count, &modes_buf);
    for (modes_buf[0..@as(usize, @intCast(count))]) |mode| switch (mode) {
        .fifo_khr => modes.insert(.fifo),
        .fifo_relaxed_khr => modes.insert(.fifo_relaxed),
        .immediate_khr => modes.insert(.immediate),
        .mailbox_khr => modes.insert(.mailbox),
        else => {},
    };
    return modes;
}

fn getSwapchainImages(allocator: std.mem.Allocator, device: *Device, swapchain: vk.SwapchainKHR) ![]vk.Image {
    var count: u32 = 0;
    _ = try device.vkd.getSwapchainImagesKHR(device.device, swapchain, &count, null);
    const images = try allocator.alloc(vk.Image, count);
    _ = try device.vkd.getSwapchainImagesKHR(device.device, swapchain, &count, images.ptr);
    return images;
}

fn isSrgbFormat(format: vk.Format) bool {
    return switch (format) {
        .b8g8r8a8_srgb, .r8g8b8a8_srgb => true,
        else => false,
    };
}
