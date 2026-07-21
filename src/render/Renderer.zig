const std = @import("std");
const gpu = @import("gpu");
const gpu_impl = @import("gpu_impl");
const text = @import("text");
const Window = @import("window").Window;
const math = @import("math");

const DrawList = @import("DrawList.zig");
const Clip = @import("Clip.zig");
const pipelines = @import("pipelines.zig");
const FrameUploads = @import("FrameUploads.zig");
const Context = @import("Context.zig");
const Texture = @import("Texture.zig");

const PhysicalViewport = @import("gpu.zig").PhysicalViewport;
const PhysicalScissor = @import("gpu.zig").PhysicalScissor;
const ClipSpaceTransform = @import("gpu.zig").ClipSpaceTransform;
const DrawContext = @import("gpu.zig").DrawContext;

const PixelTextureKey = u64;
const PIXEL_TEXTURE_TTL_FRAMES: u64 = 2;

const CURVE_TEX_WIDTH: u32 = text.GlyphBuilder.texture_width;
const BAND_TEX_WIDTH: u32 = text.GlyphBuilder.texture_width;
const INITIAL_TEX_HEIGHT: u32 = 256;

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
text_curveband_bg: gpu_impl.BindGroup,

frame_uploads: []FrameUploads,
linear_target: ?gpu_impl.Texture = null,
linear_target_bg: ?gpu_impl.BindGroup = null,
linear_target_width: u32 = 0,
linear_target_height: u32 = 0,
depth_target: ?gpu_impl.Texture = null,
depth_target_width: u32 = 0,
depth_target_height: u32 = 0,
curve_texture: gpu_impl.Texture,
band_texture: gpu_impl.Texture,
curve_tex_height: u32,
band_tex_height: u32,
pixel_textures: std.AutoHashMapUnmanaged(PixelTextureKey, PixelTextureEntry),
pixel_texture_scratch: std.ArrayList(PixelTextureKey),
frame_index: u64,
readback: ReadbackState,

const Renderer = @This();

const ReadbackState = union(enum) {
    idle,
    requested: std.mem.Allocator,
    ready: gpu.SurfaceReadback,
};

const PixelTextureEntry = struct {
    texture: *Texture,
    data_ptr: usize,
    len: usize,
    width: u32,
    height: u32,
    format: gpu.Texture.Format,
    bytes_per_row: ?u32,
    version: u64,
    last_seen: u64,
};

pub fn create(allocator: std.mem.Allocator, context: *Context, window: *const Window, cfg: Config) !*Renderer {
    const fb = window.getFramebufferSize();
    const surface_cfg = gpu.Context.Config{
        .window_width = fb.width,
        .window_height = fb.height,
        .present_mode = cfg.present_mode,
    };

    const surface = try allocator.create(gpu_impl.Surface);
    errdefer allocator.destroy(surface);
    surface.* = gpu_impl.Surface.init(&context.device, window.getWindowHandle(), surface_cfg) catch |err| switch (err) {
        error.UnsupportedPresentMode => return error.UnsupportedPresentMode,
        else => return mapFrameError(err),
    };
    errdefer surface.deinit();

    var frame = try gpu_impl.Frame.create(surface);
    errdefer frame.deinit();

    const device = &context.device;

    var curve_texture = try device.createTexture(.{
        .width = CURVE_TEX_WIDTH,
        .height = INITIAL_TEX_HEIGHT,
        .format = .rgba32f,
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .label = "glyph_curves",
    });
    errdefer curve_texture.deinit();

    var band_texture = try device.createTexture(.{
        .width = BAND_TEX_WIDTH,
        .height = INITIAL_TEX_HEIGHT,
        .format = .rgba32u,
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .label = "glyph_bands",
    });
    errdefer band_texture.deinit();

    var text_curveband_bg = try device.createBindGroup(.{
        .label = "text_curveband_bg",
        .pipeline = &context.text_pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &curve_texture } },
            .{ .binding = 1, .resource = .{ .texture_view = &band_texture } },
        },
    });
    errdefer text_curveband_bg.deinit();

    const uploads = try allocator.alloc(FrameUploads, @intCast(frame.uploadSlotCount()));
    errdefer allocator.free(uploads);
    var upload_count: usize = 0;
    errdefer for (uploads[0..upload_count]) |*u| u.deinit();
    for (uploads) |*u| {
        u.* = try .init(context);
        upload_count += 1;
    }

    const self = try allocator.create(Renderer);
    self.* = .{
        .allocator = allocator,
        .context = context,
        .cfg = cfg,
        .surface = surface,
        .frame = frame,
        .text_curveband_bg = text_curveband_bg,
        .frame_uploads = uploads,
        .curve_texture = curve_texture,
        .band_texture = band_texture,
        .curve_tex_height = INITIAL_TEX_HEIGHT,
        .band_tex_height = INITIAL_TEX_HEIGHT,
        .pixel_textures = .empty,
        .pixel_texture_scratch = .empty,
        .frame_index = 0,
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

    var texture_it = self.pixel_textures.valueIterator();
    while (texture_it.next()) |entry| entry.texture.destroyAfterWait();
    self.pixel_textures.deinit(self.allocator);
    self.pixel_texture_scratch.deinit(self.allocator);

    self.text_curveband_bg.deinit();
    for (self.frame_uploads) |*u| u.deinit();
    self.allocator.free(self.frame_uploads);

    if (self.linear_target_bg) |*bg| bg.deinit();
    if (self.linear_target) |*t| t.deinit();
    if (self.depth_target) |*t| t.deinit();
    self.curve_texture.deinit();
    self.band_texture.deinit();
    self.frame.deinit();
    self.surface.deinit();
    self.allocator.destroy(self.surface);
    self.allocator.destroy(self);
}

pub fn textureFromPixels(
    self: *Renderer,
    id: PixelTextureKey,
    data: []const u8,
    width: u32,
    height: u32,
    format: gpu.Texture.Format,
    bytes_per_row: ?u32,
    version: u64,
    force_upload: bool,
) !*const Texture {
    if (self.pixel_textures.getPtr(id)) |entry| {
        if (entry.width != width or entry.height != height or entry.format != format) {
            const replacement = try self.context.createTexture(width, height, format);
            errdefer replacement.destroyAfterWait();
            try replacement.write(data, width, height, bytes_per_row);
            try self.context.device.waitIdle();
            entry.texture.destroyAfterWait();
            entry.* = .{
                .texture = replacement,
                .data_ptr = @intFromPtr(data.ptr),
                .len = data.len,
                .width = width,
                .height = height,
                .format = format,
                .bytes_per_row = bytes_per_row,
                .version = version,
                .last_seen = self.frame_index,
            };
            return replacement;
        }

        const changed = entry.data_ptr != @intFromPtr(data.ptr) or
            entry.len != data.len or
            entry.bytes_per_row != bytes_per_row or
            entry.version != version;
        if (force_upload or changed)
            try entry.texture.write(data, width, height, bytes_per_row);
        entry.data_ptr = @intFromPtr(data.ptr);
        entry.len = data.len;
        entry.bytes_per_row = bytes_per_row;
        entry.version = version;
        entry.last_seen = self.frame_index;
        return entry.texture;
    }

    const texture = try self.context.createTexture(width, height, format);
    errdefer texture.destroyAfterWait();
    try texture.write(data, width, height, bytes_per_row);
    try self.pixel_textures.put(self.allocator, id, .{
        .texture = texture,
        .data_ptr = @intFromPtr(data.ptr),
        .len = data.len,
        .width = width,
        .height = height,
        .format = format,
        .bytes_per_row = bytes_per_row,
        .version = version,
        .last_seen = self.frame_index,
    });
    return texture;
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

pub fn render(self: *Renderer, draw_list: *const DrawList, glyph_builder: *text.GlyphBuilder, content_scale: f32) RenderResult {
    const failure = self.draw(draw_list, glyph_builder, content_scale) orelse return .success;
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

const FrameSizes = struct {
    verts_bytes: usize,
    insts_bytes: usize,
    indices_bytes: usize,
    tverts_bytes: usize,
    tindices_bytes: usize,
};

const DrawState = struct {
    clip: ?Clip.State = null,
    texture: ?*const Texture = null,
    kind: ?DrawList.Command.Kind = null,
};

fn draw(self: *Renderer, dl: *const DrawList, glyph_builder: *text.GlyphBuilder, content_scale: f32) ?RenderFailure {
    const context = self.context;
    const device = &context.device;
    var frame_ctx = self.frame.begin() catch |err| return .{ .renderer = err };
    const upload_slot: usize = @intCast(frame_ctx.upload_slot);
    std.debug.assert(upload_slot < self.frame_uploads.len);
    const upload = &self.frame_uploads[upload_slot];
    upload.resetCustom();

    self.syncGlyphBuilder(device, context, glyph_builder) catch |err| return .{ .renderer = err };
    self.syncDepthTarget(device) catch |err| return .{ .renderer = err };

    if (dl.isEmpty()) {
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
        self.sweepPixelTextures() catch |err| return .{ .renderer = err };
        return null;
    }

    self.updateViewport(upload, content_scale);
    const sizes = uploadFrameData(context, upload, dl) catch |err| return .{ .renderer = err };
    const use_linear_target = context.linear_pipeline != null;
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

    const phys_w = self.surface.cfg.window_width;
    const phys_h = self.surface.cfg.window_height;
    var state: DrawState = .{};
    var layer_it = dl.layers_dirty.iterator(.{});
    while (layer_it.next()) |z| {
        const r = dl.layer_ranges[z];
        for (dl.layer_cmds.items[r.start .. r.start + r.len]) |cmd| {
            const kind = std.meta.activeTag(cmd.payload);
            if (kind == .custom_draw) {
                const custom = cmd.payload.custom_draw;
                const region = customDrawRegion(custom.bounds, cmd.clip.scissor, content_scale, phys_w, phys_h) orelse continue;
                pass.setViewport(
                    region.viewport.x,
                    region.viewport.y,
                    region.viewport.width,
                    region.viewport.height,
                );
                pass.setScissorRect(
                    region.scissor.x,
                    region.scissor.y,
                    region.scissor.width,
                    region.scissor.height,
                );
                var public_context: DrawContext = .{
                    .context = .{ .inner = context },
                    .frame = .{ .inner = upload },
                    .pass = .{ .inner = &pass },
                    .logical_bounds = .{
                        .x = custom.bounds.x(),
                        .y = custom.bounds.y(),
                        .width = custom.bounds.w(),
                        .height = custom.bounds.h(),
                    },
                    .viewport = region.viewport,
                    .scissor = region.scissor,
                    .clip_space_transform = region.clip_space_transform,
                    .content_scale = content_scale,
                };
                custom.callback(custom.user_data, &public_context) catch |callback_error| {
                    pass.end();
                    self.finishFrame(&frame_ctx, upload, content_scale, use_linear_target) catch |err| return .{ .renderer = err };
                    return .{ .callback = callback_error };
                };

                pass.setViewport(0, 0, @floatFromInt(phys_w), @floatFromInt(phys_h));
                state = .{};
                continue;
            }

            if (!context.atlas.isReady()) continue;

            if (state.kind != kind) {
                bindKind(context, &self.text_curveband_bg, &pass, upload, kind, sizes, use_linear_target);
                state.texture = null;
                state.kind = kind;
            }
            const texture = switch (cmd.payload) {
                .vertex => |value| value.texture,
                .instance => |value| value.texture,
                .text => null,
                .custom_draw => unreachable,
            };
            if (kind != .text and texture != state.texture) {
                pass.setBindGroup(1, if (texture) |value| &value.bind_group else &context.atlas.bind_group);
                state.texture = texture;
            }
            if (state.clip == null or !state.clip.?.scissorEql(cmd.clip)) {
                applyClip(&pass, cmd.clip.scissor, content_scale, phys_w, phys_h);
                state.clip = cmd.clip;
            }
            switch (cmd.payload) {
                .vertex => |value| pass.drawIndexed(value.count, 1, value.offset, 0, 0),
                .instance => |value| pass.drawIndexed(6, value.count, 0, 0, value.offset),
                .text => |value| pass.drawIndexed(value.count, 1, value.offset, 0, 0),
                .custom_draw => unreachable,
            }
        }
    }
    pass.end();

    self.finishFrame(&frame_ctx, upload, content_scale, use_linear_target) catch |err| return .{ .renderer = err };
    self.sweepPixelTextures() catch |err| return .{ .renderer = err };
    return null;
}

fn finishFrame(self: *Renderer, frame_ctx: *gpu_impl.Frame.Context, upload: *FrameUploads, content_scale: f32, use_linear_target: bool) !void {
    if (use_linear_target) try self.compositeLinearTarget(self.context, frame_ctx, upload, content_scale);
    try self.submitFrame(frame_ctx);
}

fn sweepPixelTextures(self: *Renderer) !void {
    self.pixel_texture_scratch.clearRetainingCapacity();
    var it = self.pixel_textures.iterator();
    while (it.next()) |entry| {
        if (self.frame_index -% entry.value_ptr.last_seen >= PIXEL_TEXTURE_TTL_FRAMES)
            try self.pixel_texture_scratch.append(self.allocator, entry.key_ptr.*);
    }
    if (self.pixel_texture_scratch.items.len > 0) {
        try self.frame.waitForCompletion();
        for (self.pixel_texture_scratch.items) |key| {
            if (self.pixel_textures.fetchRemove(key)) |removed| removed.value.texture.destroyAfterWait();
        }
    }

    self.frame_index +%= 1;
}

fn submitFrame(self: *Renderer, frame: *gpu_impl.Frame.Context) !void {
    const allocator = switch (self.readback) {
        .requested => |allocator| allocator,
        else => return frame.submit(),
    };
    self.readback = .idle;
    self.readback = .{ .ready = try frame.submitReadback(allocator) };
}

fn updateViewport(self: *Renderer, uploads: *FrameUploads, content_scale: f32) void {
    const phys_w_u = self.surface.cfg.window_width;
    const phys_h_u = self.surface.cfg.window_height;
    const logical_w: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(phys_w_u)) / content_scale)));
    const logical_h: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(phys_h_u)) / content_scale)));

    const w_f: f32 = @floatFromInt(logical_w);
    const h_f: f32 = @floatFromInt(logical_h);
    const viewport: pipelines.ViewportUniform = .{ w_f, h_f };
    uploads.vertex_uniform_buf.load(pipelines.ViewportUniform, &.{viewport});
    uploads.instance_uniform_buf.load(pipelines.ViewportUniform, &.{viewport});

    const phys_w: f32 = @floatFromInt(phys_w_u);
    const phys_h: f32 = @floatFromInt(phys_h_u);
    const u = pipelines.computeSlugUniforms(w_f, h_f, phys_w, phys_h, gpu_impl.Device.clip_space_y_down);
    uploads.text_uniform_buf.load(pipelines.SlugUniforms, &.{u});
}

fn uploadFrameData(context: *Context, uploads: *FrameUploads, dl: *const DrawList) !FrameSizes {
    const verts = dl.vertices.items;
    const insts = dl.instances.items;
    const tverts = dl.text_vertices.items;
    const empty_clip_nodes = [_]Clip.Node{Clip.Node.empty};
    const clip_nodes = if (dl.clip_nodes.items.len > 0) dl.clip_nodes.items else empty_clip_nodes[0..];
    try ensureAndLoad(&uploads.vertex_buf, gpu.Vertex, verts);
    try ensureAndLoad(&uploads.instance_buf, gpu.Instance, insts);
    try ensureAndLoad(&uploads.index_buf, u32, dl.indices.items);
    try ensureAndLoad(&uploads.text_vertex_buf, gpu.SlugVertex, tverts);
    try ensureAndLoad(&uploads.text_index_buf, u32, dl.text_indices.items);
    try uploads.ensureClipNodeCapacity(context, clip_nodes.len * @sizeOf(Clip.Node));
    uploads.clip_node_buf.load(Clip.Node, clip_nodes);
    return .{
        .verts_bytes = verts.len * @sizeOf(gpu.Vertex),
        .insts_bytes = insts.len * @sizeOf(gpu.Instance),
        .indices_bytes = dl.indices.items.len * @sizeOf(u32),
        .tverts_bytes = tverts.len * @sizeOf(gpu.SlugVertex),
        .tindices_bytes = dl.text_indices.items.len * @sizeOf(u32),
    };
}

fn bindKind(
    context: *Context,
    text_curveband_bg: *gpu_impl.BindGroup,
    pass: *gpu_impl.RenderPass,
    uploads: *FrameUploads,
    kind: DrawList.Command.Kind,
    sizes: FrameSizes,
    linear_target: bool,
) void {
    switch (kind) {
        .vertex => {
            const pipeline = if (linear_target) &context.linear_pipeline.? else &context.pipeline;
            pass.bindPipeline(pipeline);
            pass.setBindGroup(0, &uploads.vertex_uniform_bg);
            pass.setBindGroup(1, &context.atlas.bind_group);
            pass.setBindGroup(2, &uploads.vertex_clip_bg);
            pass.setVertexBuffer(0, &uploads.vertex_buf, 0, sizes.verts_bytes);
            pass.setIndexBuffer(&uploads.index_buf, 0, sizes.indices_bytes);
        },
        .instance => {
            const pipeline = if (linear_target) &context.linear_instance_pipeline.? else &context.instance_pipeline;
            pass.bindPipeline(pipeline);
            pass.setBindGroup(0, &uploads.instance_uniform_bg);
            pass.setBindGroup(1, &context.atlas.bind_group);
            pass.setBindGroup(2, &uploads.instance_clip_bg);
            pass.setVertexBuffer(0, &uploads.instance_buf, 0, sizes.insts_bytes);
            pass.setIndexBuffer(&context.unit_index_buf, 0, 6 * @sizeOf(u32));
        },
        .text => {
            const pipeline = if (linear_target) &context.linear_text_pipeline.? else &context.text_pipeline;
            pass.bindPipeline(pipeline);
            pass.setBindGroup(0, &uploads.text_uniform_bg);
            pass.setBindGroup(1, text_curveband_bg);
            pass.setBindGroup(2, &uploads.text_clip_bg);
            pass.setVertexBuffer(0, &uploads.text_vertex_buf, 0, sizes.tverts_bytes);
            pass.setIndexBuffer(&uploads.text_index_buf, 0, sizes.tindices_bytes);
        },
        .custom_draw => unreachable,
    }
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

const CustomDrawRegion = struct {
    viewport: PhysicalViewport,
    scissor: PhysicalScissor,
    clip_space_transform: ClipSpaceTransform,
};

fn customDrawRegion(bounds: math.Rect, clip_rect: ?math.Rect, content_scale: f32, phys_w: u32, phys_h: u32) ?CustomDrawRegion {
    if (!std.math.isFinite(content_scale) or content_scale <= 0 or !rectIsFinite(bounds) or bounds.isEmpty()) return null;

    const original_viewport: PhysicalViewport = .{
        .x = bounds.x() * content_scale,
        .y = bounds.y() * content_scale,
        .width = bounds.w() * content_scale,
        .height = bounds.h() * content_scale,
    };
    if (!std.math.isFinite(original_viewport.x) or !std.math.isFinite(original_viewport.y) or
        !std.math.isFinite(original_viewport.width) or !std.math.isFinite(original_viewport.height)) return null;

    const surface_width: f32 = @floatFromInt(phys_w);
    const surface_height: f32 = @floatFromInt(phys_h);
    const viewport_left = std.math.clamp(original_viewport.x, 0, surface_width);
    const viewport_top = std.math.clamp(original_viewport.y, 0, surface_height);
    const viewport_right = std.math.clamp(original_viewport.x + original_viewport.width, 0, surface_width);
    const viewport_bottom = std.math.clamp(original_viewport.y + original_viewport.height, 0, surface_height);
    const viewport: PhysicalViewport = .{
        .x = viewport_left,
        .y = viewport_top,
        .width = viewport_right - viewport_left,
        .height = viewport_bottom - viewport_top,
    };
    if (viewport.width <= 0 or viewport.height <= 0) return null;

    var clipped = bounds;
    if (clip_rect) |clip| {
        if (rectIsFinite(clip)) {
            if (clip.isEmpty()) return null;
            clipped = clipped.intersect(clip);
        }
    }
    const scissor = physicalScissor(clipped, content_scale, phys_w, phys_h) orelse return null;
    if (scissor.width == 0 or scissor.height == 0) return null;

    return .{
        .viewport = viewport,
        .scissor = scissor,
        .clip_space_transform = .{
            .scale = .{
                original_viewport.width / viewport.width,
                original_viewport.height / viewport.height,
            },
            .offset = .{
                (2 * (original_viewport.x + original_viewport.width * 0.5 - viewport.x) / viewport.width) - 1,
                (2 * (original_viewport.y + original_viewport.height * 0.5 - viewport.y) / viewport.height) - 1,
            },
        },
    };
}

fn applyClip(pass: *gpu_impl.RenderPass, clip_rect: ?math.Rect, content_scale: f32, phys_w: u32, phys_h: u32) void {
    if (clip_rect) |clip| {
        if (!rectIsFinite(clip)) {
            pass.setScissorRect(0, 0, phys_w, phys_h);
            return;
        }
        if (clip.isEmpty()) {
            pass.setScissorRect(0, 0, 0, 0);
            return;
        }
        const scissor = physicalScissor(clip, content_scale, phys_w, phys_h) orelse {
            pass.setScissorRect(0, 0, 0, 0);
            return;
        };
        pass.setScissorRect(scissor.x, scissor.y, scissor.width, scissor.height);
    } else {
        pass.setScissorRect(0, 0, phys_w, phys_h);
    }
}

fn physicalScissor(rect: math.Rect, content_scale: f32, phys_w: u32, phys_h: u32) ?PhysicalScissor {
    const surface_w: f32 = @floatFromInt(phys_w);
    const surface_h: f32 = @floatFromInt(phys_h);
    const left = @min(surface_w, @max(0, @floor(rect.x() * content_scale)));
    const top = @min(surface_h, @max(0, @floor(rect.y() * content_scale)));
    const right = @min(surface_w, @max(0, @ceil((rect.x() + rect.w()) * content_scale)));
    const bottom = @min(surface_h, @max(0, @ceil((rect.y() + rect.h()) * content_scale)));
    if (right < left or bottom < top) return null;
    return .{
        .x = @intFromFloat(left),
        .y = @intFromFloat(top),
        .width = @intFromFloat(right - left),
        .height = @intFromFloat(bottom - top),
    };
}

fn syncGlyphBuilder(self: *Renderer, device: *gpu_impl.Device, context: *Context, gb: *text.GlyphBuilder) !void {
    const needed_curve_h = gb.curveTextureHeight();
    const needed_band_h = gb.bandTextureHeight();

    var new_curve_texture: ?gpu_impl.Texture = null;
    var new_band_texture: ?gpu_impl.Texture = null;
    var new_curve_h = self.curve_tex_height;
    var new_band_h = self.band_tex_height;
    var new_curveband_bg: ?gpu_impl.BindGroup = null;
    errdefer if (new_curve_texture) |*t| t.deinit();
    errdefer if (new_band_texture) |*t| t.deinit();
    errdefer if (new_curveband_bg) |*bg| bg.deinit();

    if (needed_curve_h > self.curve_tex_height) {
        new_curve_h = std.math.ceilPowerOfTwo(u32, needed_curve_h) catch needed_curve_h;
        new_curve_texture = try device.createTexture(.{
            .width = CURVE_TEX_WIDTH,
            .height = new_curve_h,
            .format = .rgba32f,
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .label = "glyph_curves",
        });
    }
    if (needed_band_h > self.band_tex_height) {
        new_band_h = std.math.ceilPowerOfTwo(u32, needed_band_h) catch needed_band_h;
        new_band_texture = try device.createTexture(.{
            .width = BAND_TEX_WIDTH,
            .height = new_band_h,
            .format = .rgba32u,
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .label = "glyph_bands",
        });
    }

    if (new_curve_texture != null or new_band_texture != null) {
        const curve_for_bg = if (new_curve_texture) |*t| t else &self.curve_texture;
        const band_for_bg = if (new_band_texture) |*t| t else &self.band_texture;
        new_curveband_bg = try device.createBindGroup(.{
            .label = "text_curveband_bg",
            .pipeline = &context.text_pipeline,
            .layout_index = 1,
            .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = curve_for_bg } },
                .{ .binding = 1, .resource = .{ .texture_view = band_for_bg } },
            },
        });

        try self.frame.waitForCompletion();

        var old_curveband_bg = self.text_curveband_bg;
        self.text_curveband_bg = new_curveband_bg.?;
        new_curveband_bg = null;
        old_curveband_bg.deinit();

        if (new_curve_texture) |tex| {
            var old = self.curve_texture;
            self.curve_texture = tex;
            self.curve_tex_height = new_curve_h;
            new_curve_texture = null;
            old.deinit();
            gb.markCurveDirtyTo(needed_curve_h);
        }
        if (new_band_texture) |tex| {
            var old = self.band_texture;
            self.band_texture = tex;
            self.band_tex_height = new_band_h;
            new_band_texture = null;
            old.deinit();
            gb.markBandDirtyTo(needed_band_h);
        }
    }

    if (gb.curveDirtyRange()) |r| {
        try uploadDirtyRows(
            text.GlyphBuilder.CurveTexel,
            self.allocator,
            &self.curve_texture,
            gb.curve_data.items,
            CURVE_TEX_WIDTH,
            r.y_start,
            r.y_end,
        );
    }
    if (gb.bandDirtyRange()) |r| {
        try uploadDirtyRows(
            text.GlyphBuilder.BandTexel,
            self.allocator,
            &self.band_texture,
            gb.band_data.items,
            BAND_TEX_WIDTH,
            r.y_start,
            r.y_end,
        );
    }
    gb.markClean();
}

fn uploadDirtyRows(
    comptime T: type,
    allocator: std.mem.Allocator,
    texture: *gpu_impl.Texture,
    items: []const T,
    width: u32,
    y0: u32,
    y1_excl: u32,
) !void {
    const rows = y1_excl - y0;
    const start_idx: usize = @as(usize, y0) * @as(usize, width);
    const end_idx: usize = @as(usize, y1_excl) * @as(usize, width);
    const have_end = @min(end_idx, items.len);

    var slice = items[start_idx..have_end];
    var owned: ?[]T = null;
    defer if (owned) |o| allocator.free(o);

    if (have_end < end_idx) {
        const buf = try allocator.alloc(T, end_idx - start_idx);
        owned = buf;
        @memcpy(buf[0..(have_end - start_idx)], items[start_idx..have_end]);
        @memset(buf[(have_end - start_idx)..], std.mem.zeroes(T));
        slice = buf;
    }

    const ptr: [*]const u8 = @ptrCast(slice.ptr);
    const len = slice.len * @sizeOf(T);
    try texture.write(ptr, len, 0, y0, width, rows, null);
}

fn rectIsFinite(rect: math.Rect) bool {
    inline for (0..4) |i| if (!std.math.isFinite(rect.v[i])) return false;
    return true;
}

fn ensureBufferCapacity(buf: *gpu_impl.Buffer, required: usize) !void {
    const current_size = buf.getSize();
    if (required <= current_size) return;
    const new_size = @max(required, current_size + current_size / 2);
    try buf.resize(new_size);
}

fn ensureAndLoad(buf: *gpu_impl.Buffer, comptime T: type, items: []const T) !void {
    if (items.len == 0) return;
    try ensureBufferCapacity(buf, items.len * @sizeOf(T));
    buf.load(T, items);
}
