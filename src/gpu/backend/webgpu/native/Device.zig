const std = @import("std");
const wgpu = @import("wgpu");
const gpu = @import("gpu");

const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const Device = @This();

pub const clip_space_y_down = false;

allocator: std.mem.Allocator,
instance: wgpu.Instance,
adapter: wgpu.Adapter,
device: wgpu.Device,
queue: wgpu.Queue,
surface_format: wgpu.Texture.Format,
surface_is_srgb: bool,

pub fn init(allocator: std.mem.Allocator, window_handle: gpu.Context.WindowHandle) !Device {
    const instance = try wgpu.Instance.init();
    errdefer instance.deinit();

    var surface = try createSurface(instance, window_handle);
    defer surface.deinit();

    const adapter = try instance.requestAdapterSync(.{ .compatible_surface = surface });
    errdefer adapter.deinit();

    const capabilities = try surface.getCapabilities(adapter.adapter);
    const surface_format = try chooseSurfaceFormat(capabilities);

    const device = try adapter.requestDeviceSync(.{ .label = "knots_device", .queue_label = "knots_queue" });
    errdefer device.deinit();

    const queue = try device.getQueue();
    errdefer queue.deinit();

    return .{
        .allocator = allocator,
        .instance = instance,
        .adapter = adapter,
        .device = device,
        .queue = queue,
        .surface_format = surface_format,
        .surface_is_srgb = isSrgbFormat(surface_format),
    };
}

pub fn deinit(self: *Device) void {
    self.queue.deinit();
    self.device.deinit();
    self.adapter.deinit();
    self.instance.deinit();
}

pub fn createBuffer(self: *Device, size: usize, usage: gpu.Buffer.Usage) !Buffer {
    return Buffer.create(self.device, self.queue, size, usage);
}

pub fn createPipeline(self: *Device, desc: gpu.Pipeline.Desc) !Pipeline {
    return Pipeline.create(self.allocator, self, desc);
}

pub fn createBindGroup(self: *Device, desc: BindGroup.Desc) !BindGroup {
    return BindGroup.create(self, desc);
}

pub fn createTexture(self: *Device, desc: gpu.Texture.Desc) !Texture {
    return Texture.create(self.device, self.queue, desc);
}

pub fn createSampler(self: *Device, desc: gpu.Sampler.Desc) !Sampler {
    return Sampler.create(self.device, desc);
}

pub fn surfaceFormat(self: *const Device) gpu.Texture.Format {
    return wgpuFormatToGpu(self.surface_format);
}

pub fn surfaceIsSrgb(self: *const Device) bool {
    return self.surface_is_srgb;
}

pub fn createSurface(instance: wgpu.Instance, window_handle: gpu.Context.WindowHandle) !wgpu.Surface {
    const wgpu_handle: wgpu.RawWindowHandle = switch (window_handle) {
        .macos => |mac| .{ .macos = switch (mac) {
            .ns_view => |v| .{ .ns_view = v },
            .ns_window => |w| .{ .ns_window = w },
        } },
        .windows => |win| .{ .windows = .{ .hwnd = win.hwnd, .hinstance = win.hinstance } },
        .linux => |lin| switch (lin) {
            .x11 => |x11| .{
                .linux = .{ .x11 = .{ .display = x11.display, .window = x11.window } },
            },
            .wayland => |wl| .{
                .linux = .{ .wayland = .{ .display = wl.display, .surface = wl.surface } },
            },
        },
        .web => return error.UnsupportedPlatform,
    };
    var surface_desc = try wgpu.descriptorFromRawHandle(wgpu_handle);
    const desc = surface_desc.getDescriptor();
    return instance.createSurface(&desc);
}

fn chooseSurfaceFormat(capabilities: wgpu.Surface.Capabilities) !wgpu.Texture.Format {
    if (capabilities.formats.len < 1) {
        return error.NoSurfaceFormatFound;
    }

    for (capabilities.formats) |format|
        if (format == .bgra8_unorm_srgb)
            return .bgra8_unorm_srgb;

    for (capabilities.formats) |format|
        if (format == .rgba8_unorm_srgb)
            return .rgba8_unorm_srgb;

    for (capabilities.formats) |format| switch (format) {
        .rgba8_unorm, .bgra8_unorm, .r8_unorm, .rgba32_float, .rgba32_uint => return format,
        else => {},
    };
    return error.UnsupportedSurfaceFormat;
}

fn isSrgbFormat(format: wgpu.Texture.Format) bool {
    return switch (format) {
        .bgra8_unorm_srgb, .rgba8_unorm_srgb => true,
        else => false,
    };
}

fn wgpuFormatToGpu(f: wgpu.Texture.Format) gpu.Texture.Format {
    return switch (f) {
        .rgba8_unorm => .rgba8,
        .rgba8_unorm_srgb => .rgba8_srgb,
        .bgra8_unorm => .bgra8,
        .bgra8_unorm_srgb => .bgra8_srgb,
        .r8_unorm => .r8,
        .rgba32_float => .rgba32f,
        .rgba32_uint => .rgba32u,
        else => unreachable,
    };
}
