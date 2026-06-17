const std = @import("std");
const wgpu = @import("wgpu");
const CommonTexture = @import("gpu").Texture;

pub const NativeHandle = struct {
    texture: wgpu.Texture,
    view: wgpu.TextureView,
    format: wgpu.Texture.Format,
    width: u32,
    height: u32,
};

const Texture = @This();

const Format = CommonTexture.Format;
const Usage = CommonTexture.Usage;
const Desc = CommonTexture.Desc;

texture: wgpu.Texture,
view: wgpu.TextureView,
queue: wgpu.Queue,
width: u32,
height: u32,
format: Format,
ready: bool,
native_handle: NativeHandle,

pub fn create(_: std.mem.Allocator, device: wgpu.Device, queue: wgpu.Queue, desc: Desc) !Texture {
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
    errdefer texture.deinit();

    const view = try texture.createView(.{
        .format = wgpu_format,
    });

    return .{
        .texture = texture,
        .view = view,
        .queue = queue,
        .width = desc.width,
        .height = desc.height,
        .format = desc.format,
        .ready = false,
        .native_handle = .{
            .texture = texture,
            .view = view,
            .format = wgpu_format,
            .width = desc.width,
            .height = desc.height,
        },
    };
}

pub fn deinit(self: *Texture) void {
    self.view.deinit();
    self.texture.deinit();
}

pub fn write(self: *Texture, data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) !void {
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

fn toWgpuFormat(format: Format) wgpu.Texture.Format {
    return switch (format) {
        .rgba8 => .rgba8_unorm,
        .rgba8_srgb => .rgba8_unorm_srgb,
        .bgra8 => .bgra8_unorm,
        .bgra8_srgb => .bgra8_unorm_srgb,
        .r8 => .r8_unorm,
        .rgba32f => .rgba32_float,
        .rgba32u => .rgba32_uint,
    };
}

fn toWgpuUsage(usage: Usage) wgpu.Texture.Usage {
    return .{
        .texture_binding = usage.texture_binding,
        .copy_dst = usage.copy_dst,
        .copy_src = usage.copy_src,
        .render_attachment = usage.render_attachment,
    };
}

pub fn nativeHandle(self: *Texture) *anyopaque {
    self.native_handle = .{
        .texture = self.texture,
        .view = self.view,
        .format = toWgpuFormat(self.format),
        .width = self.width,
        .height = self.height,
    };
    return &self.native_handle;
}
