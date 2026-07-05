const js = @import("js-bridge");
const gpu = @import("gpu");
const webgpu = @import("webgpu.zig");

const Device = @import("Device.zig");

const Surface = @This();

device: *Device,
canvas: js.Value,
context: js.Value,
surface_width: u32,
surface_height: u32,
cfg: gpu.Context.Config,
present_modes: gpu.Context.PresentModes,

pub fn init(device: *Device, window_handle: gpu.Context.WindowHandle, cfg: gpu.Context.Config) !Surface {
    const selector = switch (window_handle) {
        .web => |web| web.selector,
        else => return error.UnsupportedPlatform,
    };

    const host = try webgpu.host();
    defer host.release();
    const canvas = try host.call("resolveCanvas", &.{js.Arg.string(selector)});
    errdefer canvas.release();
    const context = try canvas.call("getContext", &.{js.Arg.string("webgpu")});
    errdefer context.release();
    if (context.isNullish()) return error.CreateSurfaceError;

    var present_modes = gpu.Context.PresentModes.empty;
    present_modes.insert(.fifo);
    if (!present_modes.contains(cfg.present_mode)) return error.UnsupportedPresentMode;

    var surface: Surface = .{
        .device = device,
        .canvas = canvas,
        .context = context,
        .surface_width = cfg.window_width,
        .surface_height = cfg.window_height,
        .cfg = cfg,
        .present_modes = present_modes,
    };
    try surface.configure(cfg.window_width, cfg.window_height);
    return surface;
}

pub fn deinit(self: *Surface) void {
    self.context.callVoid("unconfigure", &.{}) catch {};
    self.context.release();
    self.canvas.release();
}

pub fn resize(self: *Surface, width: u32, height: u32) !void {
    try self.configure(width, height);
    self.cfg.window_width = width;
    self.cfg.window_height = height;
}

pub fn reconfigure(self: *Surface, cfg: gpu.Context.Config) !void {
    if (!self.present_modes.contains(cfg.present_mode)) return error.UnsupportedPresentMode;
    try self.configure(cfg.window_width, cfg.window_height);
    self.cfg = cfg;
}

pub fn supportedPresentModes(self: *const Surface) gpu.Context.PresentModes {
    return self.present_modes;
}

pub fn format(self: *const Surface) gpu.Texture.Format {
    return self.device.surfaceFormat();
}

pub fn configure(self: *Surface, width: u32, height: u32) !void {
    var desc = try js.ObjectBuilder.init();
    defer desc.finish().release();
    try desc.set("device", js.Arg.value(self.device.device));
    try desc.set("format", js.Arg.string(webgpu.formatName(self.device.surface_format)));
    try desc.set("usage", js.Arg.u32(webgpu.texture_usage.render_attachment));
    try desc.set("alphaMode", js.Arg.string("opaque"));
    try self.context.callVoid("configure", &.{js.Arg.value(desc.value)});
    self.surface_width = width;
    self.surface_height = height;
}
