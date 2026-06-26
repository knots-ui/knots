const std = @import("std");
const builtin = @import("builtin");
const wgpu = @import("wgpu");
const gpu = @import("gpu");

const Buffer = @import("Buffer.zig");
const Frame = @import("Frame.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const Context = @This();

pub const NativeDevice = struct {
    device: wgpu.Device,
    queue: wgpu.Queue,
};

allocator: std.mem.Allocator,
instance: wgpu.Instance,
adapter: wgpu.Adapter,
device: wgpu.Device,
queue: wgpu.Queue,
surface: wgpu.Surface,
surface_format: wgpu.Texture.Format,
surface_is_srgb: bool,
surface_copy_src: bool,
present_mode: wgpu.types.PresentMode,
surface_width: u32,
surface_height: u32,
cfg: gpu.Context.Config,
present_modes: gpu.Context.PresentModes,

pub fn init(allocator: std.mem.Allocator, window_handle: gpu.Context.WindowHandle, cfg: gpu.Context.Config) !Context {
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
        .emscripten => |em| .{ .emscripten = .{ .selector = em.selector } },
    };

    const instance = try wgpu.Instance.init();
    errdefer instance.deinit();

    var surface_desc = try wgpu.descriptorFromRawHandle(wgpu_handle);
    const desc = surface_desc.getDescriptor();
    const surface = try instance.createSurface(&desc);

    const adapter = try instance.requestAdapterSync(.{ .compatible_surface = surface });

    const capabilities = try surface.getCapabilities(adapter.adapter);

    const dev = try adapter.requestDeviceSync(.{ .label = "knots_device", .queue_label = "knots_queue" });

    const q = try dev.getQueue();

    const surface_format = try chooseSurfaceFormat(capabilities);
    const surface_is_srgb = isSrgbFormat(surface_format);
    const surface_copy_src = builtin.os.tag != .emscripten and capabilities.raw.usages & wgpu.c.WGPUTextureUsage_CopySrc != 0;

    const present_modes = presentModesFromCapabilities(capabilities);
    const chosen_present_mode = choosePresentMode(present_modes, cfg.present_mode) orelse return error.UnsupportedPresentMode;

    surface.configure(.{
        .width = cfg.window_width,
        .height = cfg.window_height,
        .format = surface_format,
        .device = dev,
        .present_mode = chosen_present_mode,
        .usage = .{ .copy_src = surface_copy_src, .render_attachment = true },
    });

    return .{
        .allocator = allocator,
        .instance = instance,
        .adapter = adapter,
        .device = dev,
        .queue = q,
        .surface = surface,
        .surface_format = surface_format,
        .surface_is_srgb = surface_is_srgb,
        .surface_copy_src = surface_copy_src,
        .present_mode = chosen_present_mode,
        .surface_width = cfg.window_width,
        .surface_height = cfg.window_height,
        .cfg = cfg,
        .present_modes = present_modes,
    };
}

pub fn clipSpaceYDown(_: *const Context) bool {
    return false;
}

pub fn deinit(self: *Context) void {
    self.queue.deinit();
    self.device.deinit();
    self.adapter.deinit();
    self.surface.unconfigure();
    self.surface.deinit();
    self.instance.deinit();
}

pub fn createBuffer(self: *Context, size: usize, usage: gpu.Buffer.Usage) !Buffer {
    return Buffer.create(self.allocator, self.device, self.queue, size, usage);
}

pub fn createFrame(self: *Context) !Frame {
    return Frame.create(self.allocator, self);
}

pub fn createPipeline(self: *Context, desc: gpu.Pipeline.Desc) !Pipeline {
    return Pipeline.create(self.allocator, self, desc);
}

pub fn createBindGroup(self: *Context, desc: BindGroup.Desc) !BindGroup {
    return BindGroup.create(self.allocator, self, desc);
}

pub fn createTexture(self: *Context, desc: gpu.Texture.Desc) !Texture {
    return Texture.create(self.allocator, self.device, self.queue, desc);
}

pub fn createSampler(self: *Context, desc: gpu.Sampler.Desc) !Sampler {
    return Sampler.create(self.allocator, self.device, desc);
}

pub fn resize(self: *Context, width: u32, height: u32) !void {
    self.reconfigureSurface(width, height);
    self.cfg.window_width = width;
    self.cfg.window_height = height;
}

pub fn reconfigure(self: *Context, cfg: gpu.Context.Config) !void {
    const capabilities = try self.surface.getCapabilities(self.adapter.adapter);
    const present_modes = presentModesFromCapabilities(capabilities);
    self.present_mode = choosePresentMode(present_modes, cfg.present_mode) orelse return error.UnsupportedPresentMode;
    self.reconfigureSurface(cfg.window_width, cfg.window_height);
    self.cfg = cfg;
    self.present_modes = present_modes;
}

pub fn supportedPresentModes(self: *const Context) gpu.Context.PresentModes {
    return self.present_modes;
}

pub fn reconfigureSurface(self: *Context, width: u32, height: u32) void {
    self.surface.configure(.{
        .width = width,
        .height = height,
        .format = self.surface_format,
        .device = self.device,
        .present_mode = self.present_mode,
        .usage = .{ .copy_src = self.surface_copy_src, .render_attachment = true },
    });
    self.surface_width = width;
    self.surface_height = height;
}

pub fn surfaceFormat(self: *const Context) gpu.Texture.Format {
    return wgpuFormatToGpu(self.surface_format);
}

pub fn surfaceIsSrgb(self: *const Context) bool {
    return self.surface_is_srgb;
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

fn choosePresentMode(modes: gpu.Context.PresentModes, requested: gpu.Context.PresentMode) ?wgpu.types.PresentMode {
    if (!modes.contains(requested)) return null;
    return switch (requested) {
        .fifo => .fifo,
        .fifo_relaxed => .fifo_relaxed,
        .immediate => .immediate,
        .mailbox => .mailbox,
    };
}

fn presentModesFromCapabilities(capabilities: wgpu.Surface.Capabilities) gpu.Context.PresentModes {
    var modes = gpu.Context.PresentModes.empty;
    for (capabilities.present_modes) |mode| switch (mode) {
        .fifo => modes.insert(.fifo),
        .fifo_relaxed => modes.insert(.fifo_relaxed),
        .immediate => modes.insert(.immediate),
        .mailbox => modes.insert(.mailbox),
        else => {},
    };
    return modes;
}
