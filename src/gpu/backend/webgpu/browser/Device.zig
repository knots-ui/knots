const std = @import("std");
const js = @import("js-bridge");
const gpu = @import("gpu");
const webgpu = @import("webgpu.zig");

const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const Device = @This();

pub const clip_space_y_down = false;

allocator: std.mem.Allocator,
adapter: js.Value,
device: js.Value,
queue: js.Value,
surface_format: gpu.Texture.Format,
surface_is_srgb: bool,

pub fn init(allocator: std.mem.Allocator, _: gpu.Context.WindowHandle) !Device {
    const host = try webgpu.host();
    defer host.release();

    const adapter = try host.get("gpuAdapter");
    errdefer adapter.release();
    const device = try host.get("gpuDevice");
    errdefer device.release();
    const queue = try host.get("gpuQueue");
    errdefer queue.release();
    const preferred = try host.get("preferredFormat");
    defer preferred.release();

    const surface_format = webgpu.preferredFormat(preferred);
    return .{
        .allocator = allocator,
        .adapter = adapter,
        .device = device,
        .queue = queue,
        .surface_format = surface_format,
        .surface_is_srgb = webgpu.isSrgb(surface_format),
    };
}

pub fn deinit(self: *Device) void {
    self.queue.release();
    self.device.release();
    self.adapter.release();
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
    return self.surface_format;
}

pub fn surfaceIsSrgb(self: *const Device) bool {
    return self.surface_is_srgb;
}
