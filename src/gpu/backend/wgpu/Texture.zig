const std = @import("std");
const wgpu = @import("wgpu");
const gpu = @import("gpu");

pub const NativeHandle = struct {
    texture: wgpu.Texture,
    view: wgpu.TextureView,
    format: wgpu.Texture.Format,
    width: u32,
    height: u32,
};

const Texture = @This();

allocator: std.mem.Allocator,
texture: wgpu.Texture,
view: wgpu.TextureView,
queue: wgpu.Queue,
width: u32,
height: u32,
format: gpu.Texture.Format,
ready: bool,
_native_handle: NativeHandle = undefined,

pub fn create(allocator: std.mem.Allocator, device: wgpu.Device, queue: wgpu.Queue, desc: gpu.Texture.Desc) !gpu.Texture {
    const wgpu_format = toWgpuFormat(desc.format);

    const texture = try device.createTexture(.{
        .label = if (desc.label.len > 0) desc.label else "",
        .size = .{ .width = desc.width, .height = desc.height, .depth_or_array_layers = 1 },
        .format = wgpu_format,
        .usage = toWgpuUsage(desc.usage),
        .mip_level_count = 1,
        .sample_count = 1,
        .dimension = .@"2d",
    });

    const view = try texture.createView(.{
        .format = wgpu_format,
    });

    const self = try allocator.create(Texture);
    self.* = .{
        .allocator = allocator,
        .texture = texture,
        .view = view,
        .queue = queue,
        .width = desc.width,
        .height = desc.height,
        .format = desc.format,
        .ready = false,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = gpu.Texture.VTable{
    .deinit = &deinit,
    .write = &write,
    .is_ready = &isReady,
    .nativeHandle = &nativeHandle,
};

fn deinit(ptr: *anyopaque) void {
    const self: *Texture = @ptrCast(@alignCast(ptr));
    self.view.deinit();
    self.texture.deinit();
    self.allocator.destroy(self);
}

fn write(ptr: *anyopaque, data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) !void {
    const self: *Texture = @ptrCast(@alignCast(ptr));
    const bpr = bytes_per_row orelse width * bytesPerPixel(self.format);
    self.queue.writeTexture(
        u8,
        .{ .texture = self.texture, .origin = .{ .x = x, .y = y, .z = 0 } },
        data[0..len],
        .{ .bytes_per_row = bpr, .rows_per_image = height },
        .{ .width = width, .height = height, .depth_or_array_layers = 1 },
    );
    self.ready = true;
}

fn isReady(ptr: *anyopaque) bool {
    const self: *Texture = @ptrCast(@alignCast(ptr));
    return self.ready;
}

fn bytesPerPixel(format: gpu.Texture.Format) u32 {
    return switch (format) {
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .r8 => 1,
    };
}

fn toWgpuFormat(format: gpu.Texture.Format) wgpu.Texture.Format {
    return switch (format) {
        .rgba8 => .rgba8_unorm,
        .rgba8_srgb => .rgba8_unorm_srgb,
        .bgra8 => .bgra8_unorm,
        .bgra8_srgb => .bgra8_unorm_srgb,
        .r8 => .r8_unorm,
    };
}

fn toWgpuUsage(usage: gpu.Texture.Usage) wgpu.Texture.Usage {
    return .{
        .texture_binding = usage.texture_binding,
        .copy_dst = usage.copy_dst,
        .copy_src = usage.copy_src,
        .render_attachment = usage.render_attachment,
    };
}

fn nativeHandle(ptr: *anyopaque) *anyopaque {
    const self: *Texture = @ptrCast(@alignCast(ptr));
    self._native_handle = .{
        .texture = self.texture,
        .view = self.view,
        .format = toWgpuFormat(self.format),
        .width = self.width,
        .height = self.height,
    };
    return &self._native_handle;
}
