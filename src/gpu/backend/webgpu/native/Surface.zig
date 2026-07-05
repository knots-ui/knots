const builtin = @import("builtin");
const wgpu = @import("wgpu");
const gpu = @import("gpu");

const Device = @import("Device.zig");
const is_browser_wasm = switch (builtin.cpu.arch) {
    .wasm32, .wasm64 => true,
    else => false,
} and builtin.os.tag == .freestanding;

const Surface = @This();

device: *Device,
surface: wgpu.Surface,
surface_copy_src: bool,
present_mode: wgpu.types.PresentMode,
surface_width: u32,
surface_height: u32,
cfg: gpu.Context.Config,
present_modes: gpu.Context.PresentModes,

pub fn init(device: *Device, window_handle: gpu.Context.WindowHandle, cfg: gpu.Context.Config) !Surface {
    const surface = try Device.createSurface(device.instance, window_handle);
    errdefer surface.deinit();

    const capabilities = try surface.getCapabilities(device.adapter.adapter);
    const surface_format = try requireSurfaceFormat(capabilities, device.surface_format);
    const surface_copy_src = !is_browser_wasm and capabilities.raw.usages & wgpu.c.WGPUTextureUsage_CopySrc != 0;
    const present_modes = presentModesFromCapabilities(capabilities);
    const chosen_present_mode = choosePresentMode(present_modes, cfg.present_mode) orelse return error.UnsupportedPresentMode;

    surface.configure(.{
        .width = cfg.window_width,
        .height = cfg.window_height,
        .format = surface_format,
        .device = device.device,
        .present_mode = chosen_present_mode,
        .usage = .{ .copy_src = surface_copy_src, .render_attachment = true },
    });

    return .{
        .device = device,
        .surface = surface,
        .surface_copy_src = surface_copy_src,
        .present_mode = chosen_present_mode,
        .surface_width = cfg.window_width,
        .surface_height = cfg.window_height,
        .cfg = cfg,
        .present_modes = present_modes,
    };
}

pub fn deinit(self: *Surface) void {
    self.surface.unconfigure();
    self.surface.deinit();
}

pub fn resize(self: *Surface, width: u32, height: u32) !void {
    self.configure(width, height);
    self.cfg.window_width = width;
    self.cfg.window_height = height;
}

pub fn reconfigure(self: *Surface, cfg: gpu.Context.Config) !void {
    const device = self.device;
    const capabilities = try self.surface.getCapabilities(device.adapter.adapter);
    const present_modes = presentModesFromCapabilities(capabilities);
    self.present_mode = choosePresentMode(present_modes, cfg.present_mode) orelse return error.UnsupportedPresentMode;
    self.configure(cfg.window_width, cfg.window_height);
    self.cfg = cfg;
    self.present_modes = present_modes;
}

pub fn supportedPresentModes(self: *const Surface) gpu.Context.PresentModes {
    return self.present_modes;
}

pub fn format(self: *const Surface) gpu.Texture.Format {
    return self.device.surfaceFormat();
}

pub fn configure(self: *Surface, width: u32, height: u32) void {
    const device = self.device;
    self.surface.configure(.{
        .width = width,
        .height = height,
        .format = device.surface_format,
        .device = device.device,
        .present_mode = self.present_mode,
        .usage = .{ .copy_src = self.surface_copy_src, .render_attachment = true },
    });
    self.surface_width = width;
    self.surface_height = height;
}

fn requireSurfaceFormat(capabilities: wgpu.Surface.Capabilities, required: wgpu.Texture.Format) !wgpu.Texture.Format {
    for (capabilities.formats) |f| {
        if (f == required) return required;
    }
    return error.SurfaceFormatMismatch;
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
