const std = @import("std");
const gpu = @import("gpu");
const gpu_impl = @import("gpu_impl");
const Packet = @import("render").Packet;

const FrameUploads = @import("FrameUploads.zig");
const Context = @import("Context.zig");

const Painter = @import("Painter.zig");
pub const RenderError =
    gpu.Context.SurfaceError ||
    gpu.SurfaceReadback.Error ||
    gpu.Context.BackendError;

const FrameError = gpu.Context.SurfaceError || gpu.Context.BackendError;

pub const Config = struct {
    present_mode: gpu.Context.PresentMode = .fifo,
    clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
};

pub const ResizeError = FrameError;
pub const ReconfigureError = error{UnsupportedPresentMode} || FrameError;

allocator: std.mem.Allocator,
context: *Context,
cfg: Config,
surface: *gpu_impl.Surface,
frame: gpu_impl.Frame,
painter: *Painter,
linear_target: ?gpu_impl.Texture = null,
linear_target_bg: ?gpu_impl.BindGroup = null,
linear_target_width: u32 = 0,
linear_target_height: u32 = 0,
depth_target: ?gpu_impl.Texture = null,
depth_target_width: u32 = 0,
depth_target_height: u32 = 0,
readback: ReadbackState,

const Renderer = @This();

const ReadbackState = union(enum) {
    idle,
    requested: std.mem.Allocator,
    ready: gpu.SurfaceReadback,
};

pub fn create(allocator: std.mem.Allocator, context: *Context, window_handle: gpu.Context.WindowHandle, framebuffer_width: u32, framebuffer_height: u32, cfg: Config) !*Renderer {
    const surface_cfg = gpu.Context.Config{
        .window_width = framebuffer_width,
        .window_height = framebuffer_height,
        .present_mode = cfg.present_mode,
    };

    const surface = try allocator.create(gpu_impl.Surface);
    errdefer allocator.destroy(surface);
    surface.* = gpu_impl.Surface.init(context.device, window_handle, surface_cfg) catch |err| switch (err) {
        error.UnsupportedPresentMode => return error.UnsupportedPresentMode,
        else => return mapFrameError(err),
    };
    errdefer surface.deinit();

    var frame = try gpu_impl.Frame.create(surface);
    errdefer frame.deinit();

    const painter = try Painter.create(allocator, context, frame.uploadSlotCount());
    errdefer painter.destroyAfterWait();
    const self = try allocator.create(Renderer);
    self.* = .{
        .allocator = allocator,
        .context = context,
        .cfg = cfg,
        .surface = surface,
        .frame = frame,
        .painter = painter,
        .readback = .idle,
    };
    return self;
}
pub fn destroy(self: *Renderer) void {
    std.debug.assert(self.linearTargetStateValid());
    switch (self.readback) {
        .ready => |*readback| readback.deinit(),
        else => {},
    }
    self.frame.waitForCompletion() catch {};

    self.painter.destroyAfterWait();

    if (self.linear_target_bg) |*bg| bg.deinit();
    if (self.linear_target) |*t| t.deinit();
    if (self.depth_target) |*t| t.deinit();
    self.frame.deinit();
    self.surface.deinit();
    self.allocator.destroy(self.surface);
    self.allocator.destroy(self);
}

pub fn resize(self: *Renderer, width: u32, height: u32) ResizeError!void {
    const current_width = self.surface.cfg.window_width;
    const current_height = self.surface.cfg.window_height;
    if (width == current_width and height == current_height) return;
    self.frame.prepareResize();
    self.surface.resize(width, height) catch |err| return mapFrameError(err);
}

/// Updates per-window renderer config. Present-mode changes reconfigure only
/// this renderer's surface; shared GPU resources stay alive.
pub fn reconfigure(self: *Renderer, new_cfg: Config) ReconfigureError!void {
    if (std.meta.eql(new_cfg, self.cfg)) return;

    if (new_cfg.present_mode != self.cfg.present_mode) {
        var surface_cfg = self.surface.cfg;
        surface_cfg.present_mode = new_cfg.present_mode;
        self.frame.waitForCompletion() catch |err| return mapFrameError(err);
        self.frame.prepareResize();
        self.surface.reconfigure(surface_cfg) catch |err| {
            if (err == error.UnsupportedPresentMode) return error.UnsupportedPresentMode;
            return mapFrameError(err);
        };
    }
    self.cfg = new_cfg;
}

pub fn supportedPresentModes(self: *const Renderer) gpu.Context.PresentModes {
    return self.surface.supportedPresentModes();
}

pub fn requestReadback(self: *Renderer, allocator: std.mem.Allocator) !void {
    switch (self.readback) {
        .idle => self.readback = .{ .requested = allocator },
        else => return error.ReadbackPending,
    }
}

pub fn takeReadback(self: *Renderer) ?gpu.SurfaceReadback {
    return switch (self.readback) {
        .ready => |readback| blk: {
            self.readback = .idle;
            break :blk readback;
        },
        else => null,
    };
}

pub const RenderResult = union(enum) {
    success,
    callback_error: anyerror,
    renderer_error: RenderError,
};

const RenderFailure = union(enum) {
    callback: anyerror,
    renderer: anyerror,
};

/// Upload resources, encode, submit, and present to this renderer's owned surface.
/// The packet is borrowed for this call; texture handles must outlive GPU work.
pub fn render(self: *Renderer, packet: *const Packet, content_scale: f32) RenderResult {
    std.debug.assert(packet.commands().len <= Packet.commands_max);
    std.debug.assert(std.math.isFinite(content_scale));
    std.debug.assert(content_scale > 0);
    const failure = self.draw(packet, content_scale) orelse return .success;
    return switch (failure) {
        .callback => |err| .{ .callback_error = err },
        .renderer => |err| .{ .renderer_error = mapRenderError(err) },
    };
}

fn mapRenderError(err: anyerror) RenderError {
    return switch (err) {
        error.SurfaceReadbackUnsupported => error.SurfaceReadbackUnsupported,
        error.SurfaceReadbackUnavailable => error.SurfaceReadbackUnavailable,
        error.SurfaceReadbackTooLarge => error.SurfaceReadbackTooLarge,
        error.SurfaceReadbackMapFailed,
        error.SurfaceReadbackFailed,
        => error.SurfaceReadbackFailed,

        else => mapFrameError(err),
    };
}

fn mapFrameError(err: anyerror) FrameError {
    return switch (err) {
        error.SurfaceUnavailable,
        error.OutOfDateKHR,
        error.CurrentTextureOutdated,
        error.CurrentTextureTimeout,
        error.Timeout,
        error.NotReady,
        => error.SurfaceUnavailable,

        error.SurfaceLostKHR,
        error.CurrentTextureLost,
        error.FullScreenExclusiveModeLostEXT,
        error.SurfaceFormatMismatch,
        error.NoCompatibleSurface,
        error.SwapchainFormatChanged,
        => error.SurfaceLost,

        else => mapBackendError(err),
    };
}

fn mapBackendError(err: anyerror) gpu.Context.BackendError {
    return switch (err) {
        error.OutOfMemory,
        error.OutOfHostMemory,
        error.OutOfDeviceMemory,
        error.CurrentTextureOutOfMemory,
        => error.OutOfMemory,

        error.DeviceLost,
        error.CurrentTextureDeviceLost,
        => error.DeviceLost,

        else => error.BackendFailure,
    };
}

fn draw(self: *Renderer, dl: *const Packet, content_scale: f32) ?RenderFailure {
    const context = self.context;
    const device = context.device;
    var frame_ctx = self.frame.begin() catch |err| return .{ .renderer = err };
    self.syncDepthTarget(device) catch |err| return .{ .renderer = err };
    if (dl.commands().len == 0) {
        var pass = frame_ctx.beginRenderPass(.{
            .label = "ui",
            .color_attachment = .{ .clear_color = self.cfg.clear_color },
            .depth_attachment = if (self.depth_target) |*target|
                .{ .store_op = .discard, .target = target }
            else
                null,
        }) catch |err| return .{ .renderer = err };
        pass.end();
        self.submitFrame(&frame_ctx) catch |err| return .{ .renderer = err };
        return null;
    }

    const use_linear_target = context.linear_pipeline != null;
    const prepared = self.painter.prepare(dl, &.{
        .width = self.surface.cfg.window_width,
        .height = self.surface.cfg.window_height,
        .content_scale = content_scale,
        .upload_slot = frame_ctx.upload_slot,
        .frame_context = frame_ctx,
        .linear_target = use_linear_target,
    }) catch |err| return .{ .renderer = err };
    const upload = &self.painter.frame_uploads[frame_ctx.upload_slot];
    if (use_linear_target) self.ensureLinearTarget(device, context) catch |err| return .{ .renderer = err };

    var pass = if (use_linear_target)
        frame_ctx.beginRenderPass(.{
            .label = "ui_linear",
            .color_attachment = .{
                .clear_color = self.cfg.clear_color,
                .target = &self.linear_target.?,
            },
            .depth_attachment = if (self.depth_target) |*target|
                .{ .store_op = .discard, .target = target }
            else
                null,
        }) catch |err| return .{ .renderer = err }
    else
        frame_ctx.beginRenderPass(.{
            .label = "ui",
            .color_attachment = .{ .clear_color = self.cfg.clear_color },
            .depth_attachment = if (self.depth_target) |*target|
                .{ .store_op = .discard, .target = target }
            else
                null,
        }) catch |err| return .{ .renderer = err };

    self.painter.encode(&prepared, &pass) catch |err| {
        pass.end();
        self.finishFrame(&frame_ctx, upload, content_scale, use_linear_target) catch |failure| return .{ .renderer = failure };
        return .{ .callback = err };
    };
    pass.end();

    self.finishFrame(&frame_ctx, upload, content_scale, use_linear_target) catch |err| return .{ .renderer = err };
    return null;
}

fn finishFrame(self: *Renderer, frame_ctx: *gpu_impl.Frame.Context, upload: *FrameUploads, content_scale: f32, use_linear_target: bool) !void {
    if (use_linear_target) try self.compositeLinearTarget(self.context, frame_ctx, upload, content_scale);
    try self.submitFrame(frame_ctx);
}

fn submitFrame(self: *Renderer, frame: *gpu_impl.Frame.Context) !void {
    const allocator = switch (self.readback) {
        .requested => |allocator| allocator,
        else => return frame.submit(),
    };
    self.readback = .idle;
    self.readback = .{ .ready = try frame.submitReadback(allocator) };
}

fn ensureLinearTarget(self: *Renderer, device: *gpu_impl.Device, context: *Context) !void {
    const w = self.surface.cfg.window_width;
    const h = self.surface.cfg.window_height;
    std.debug.assert(self.linearTargetStateValid());
    if (self.linear_target != null) {
        if (self.linear_target_width == w) {
            if (self.linear_target_height == h) return;
        }
    }

    try self.frame.waitForCompletion();
    var new_target = try device.createTexture(.{
        .width = w,
        .height = h,
        .format = .rgba8,
        .usage = .{ .texture_binding = true, .render_attachment = true },
        .label = "linear_ui_target",
    });
    errdefer new_target.deinit();

    var new_target_bg = try device.createBindGroup(.{
        .label = "linear_ui_target_bg",
        .pipeline = &context.instance_pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &new_target } },
            .{ .binding = 1, .resource = .{ .sampler = &context.linear_sampler.? } },
        },
    });
    errdefer new_target_bg.deinit();

    var old_target = self.linear_target;
    var old_target_bg = self.linear_target_bg;
    self.linear_target = new_target;
    self.linear_target_bg = new_target_bg;
    self.linear_target_width = w;
    self.linear_target_height = h;
    if (old_target_bg) |*bind_group| bind_group.deinit();
    if (old_target) |*target| target.deinit();
    std.debug.assert(self.linearTargetStateValid());
}

fn linearTargetStateValid(self: *const Renderer) bool {
    if (self.linear_target) |_| {
        if (self.linear_target_bg == null) return false;
        if (self.linear_target_width == 0) return false;
        if (self.linear_target_height == 0) return false;
        return true;
    }
    if (self.linear_target_bg != null) return false;
    if (self.linear_target_width != 0) return false;
    if (self.linear_target_height != 0) return false;
    return true;
}

fn syncDepthTarget(self: *Renderer, device: *gpu_impl.Device) !void {
    const width = self.surface.cfg.window_width;
    const height = self.surface.cfg.window_height;
    if (!self.context.depth_buffer or width == 0 or height == 0) {
        if (self.depth_target == null) return;
        try self.frame.waitForCompletion();
        if (self.depth_target) |*target| target.deinit();
        self.depth_target = null;
        self.depth_target_width = 0;
        self.depth_target_height = 0;
        return;
    }
    if (self.depth_target != null and
        self.depth_target_width == width and
        self.depth_target_height == height)
    {
        return;
    }

    try self.frame.waitForCompletion();
    if (self.depth_target) |*target| target.deinit();
    self.depth_target = null;
    self.depth_target_width = 0;
    self.depth_target_height = 0;
    self.depth_target = try device.createTexture(.{
        .width = width,
        .height = height,
        .format = .depth24_plus,
        .usage = .{ .render_attachment = true },
        .label = "ui_depth_target",
    });
    self.depth_target_width = width;
    self.depth_target_height = height;
}

fn compositeLinearTarget(self: *Renderer, context: *Context, frame_ctx: *gpu_impl.Frame.Context, uploads: *FrameUploads, content_scale: f32) !void {
    std.debug.assert(self.linearTargetStateValid());
    const width = self.surface.cfg.window_width;
    const height = self.surface.cfg.window_height;
    const logical_w: f32 = @as(f32, @floatFromInt(width)) / content_scale;
    const logical_h: f32 = @as(f32, @floatFromInt(height)) / content_scale;
    const inst = gpu.Instance{
        .pos = .{ 0, 0 },
        .size = .{ logical_w, logical_h },
        .uv0 = .{ 0, 0 },
        .uv1 = .{ 1, 1 },
        .color = .{ 1, 1, 1, 1 },
        .border_color = .{ 0, 0, 0, 0 },
        .corner_radius = .{ 0, 0, 0, 0 },
        .border_width = .{ 0, 0, 0, 0 },
        .prim_type = 2.0,
    };
    uploads.composite_instance_buf.load(gpu.Instance, &.{inst});

    var pass = try frame_ctx.beginRenderPass(.{
        .label = "ui_composite",
        .color_attachment = .{ .clear_color = self.cfg.clear_color },
        .depth_attachment = if (self.depth_target) |*target|
            .{ .store_op = .discard, .target = target }
        else
            null,
    });
    pass.bindPipeline(&context.instance_pipeline);
    pass.setBindGroup(0, &uploads.instance_uniform_bg);
    pass.setBindGroup(1, &self.linear_target_bg.?);
    pass.setBindGroup(2, &uploads.instance_clip_bg);
    pass.setVertexBuffer(0, &uploads.composite_instance_buf, 0, @sizeOf(gpu.Instance));
    pass.setIndexBuffer(&context.unit_index_buf, 0, 6 * @sizeOf(u32));
    pass.setScissorRect(0, 0, width, height);
    pass.drawIndexed(6, 1, 0, 0, 0);
    pass.end();
}
