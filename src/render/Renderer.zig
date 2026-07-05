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
const RendererGroup = @import("RendererGroup.zig");
const RenderTarget = @import("RenderTarget.zig");
const Shared = @import("Shared.zig");

const PixelTextureKey = u64;

const CURVE_TEX_WIDTH: u32 = text.GlyphBuilder.TEXTURE_WIDTH;
const BAND_TEX_WIDTH: u32 = text.GlyphBuilder.TEXTURE_WIDTH;
const INITIAL_TEX_HEIGHT: u32 = 256;

pub const EndFrameError =
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
group: *RendererGroup,
cfg: Config,
target: RenderTarget,
text_curveband_bg: gpu_impl.BindGroup,

frame_uploads: []FrameUploads,
linear_target: ?gpu_impl.Texture = null,
linear_target_bg: ?gpu_impl.BindGroup = null,
linear_target_width: u32 = 0,
linear_target_height: u32 = 0,
curve_texture: gpu_impl.Texture,
band_texture: gpu_impl.Texture,
curve_tex_height: u32,
band_tex_height: u32,
draw_list: DrawList,
readback: ReadbackState,

const Renderer = @This();

const ReadbackState = union(enum) {
    idle,
    requested: std.mem.Allocator,
    ready: gpu.SurfaceReadback,
};

pub fn init(allocator: std.mem.Allocator, group: *RendererGroup, window: *const Window, cfg: Config) !Renderer {
    const fb = window.getFramebufferSize();
    const surface_cfg = gpu.Context.Config{
        .window_width = fb.width,
        .window_height = fb.height,
        .present_mode = cfg.present_mode,
    };

    var target = RenderTarget.init(allocator, group.device, window, surface_cfg) catch |err| switch (err) {
        error.UnsupportedPresentMode => return error.UnsupportedPresentMode,
        else => return mapFrameError(err),
    };
    errdefer target.deinit();

    const device = group.device;
    const shared = &group.shared;

    var curve_texture = try device.createTexture(.{
        .width = CURVE_TEX_WIDTH,
        .height = INITIAL_TEX_HEIGHT,
        .format = .rgba32f,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer curve_texture.deinit();

    var band_texture = try device.createTexture(.{
        .width = BAND_TEX_WIDTH,
        .height = INITIAL_TEX_HEIGHT,
        .format = .rgba32u,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer band_texture.deinit();

    var text_curveband_bg = try device.createBindGroup(.{
        .label = "text_curveband_bg",
        .pipeline = &shared.text_pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &curve_texture } },
            .{ .binding = 1, .resource = .{ .texture_view = &band_texture } },
        },
    });
    errdefer text_curveband_bg.deinit();

    const uploads = try allocator.alloc(FrameUploads, @intCast(target.uploadSlotCount()));
    errdefer allocator.free(uploads);
    var upload_count: usize = 0;
    errdefer for (uploads[0..upload_count]) |*u| u.deinit();
    for (uploads) |*u| {
        u.* = try .init(device, &shared.pipeline, &shared.instance_pipeline, &shared.text_pipeline);
        upload_count += 1;
    }
    group.noteUploadSlotCount(target.uploadSlotCount());

    return .{
        .allocator = allocator,
        .group = group,
        .cfg = cfg,
        .target = target,
        .text_curveband_bg = text_curveband_bg,
        .frame_uploads = uploads,
        .curve_texture = curve_texture,
        .band_texture = band_texture,
        .curve_tex_height = INITIAL_TEX_HEIGHT,
        .band_tex_height = INITIAL_TEX_HEIGHT,
        .draw_list = .init(allocator),
        .readback = .idle,
    };
}

pub fn deinit(self: *Renderer) void {
    switch (self.readback) {
        .ready => |*readback| readback.deinit(),
        else => {},
    }
    self.draw_list.deinit();
    self.target.waitForCompletion() catch {};

    self.text_curveband_bg.deinit();
    for (self.frame_uploads) |*u| u.deinit();
    self.allocator.free(self.frame_uploads);

    if (self.linear_target_bg) |*bg| bg.deinit();
    if (self.linear_target) |*t| t.deinit();
    self.curve_texture.deinit();
    self.band_texture.deinit();
    self.target.deinit();
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
) !Shared.TextureId {
    return self.group.shared.textureFromPixels(
        self.group.device,
        id,
        data,
        width,
        height,
        format,
        bytes_per_row,
        version,
        force_upload,
    );
}

pub fn resize(self: *Renderer, width: u32, height: u32) ResizeError!void {
    self.target.resize(width, height) catch |err| return mapFrameError(err);
}

/// Updates per-window renderer config. Present-mode changes reconfigure only
/// this renderer's surface; shared GPU resources stay alive.
pub fn reconfigure(self: *Renderer, new_cfg: Config) ReconfigureError!void {
    if (std.meta.eql(new_cfg, self.cfg)) return;

    if (new_cfg.present_mode != self.cfg.present_mode) {
        var surface_cfg = self.target.config();
        surface_cfg.present_mode = new_cfg.present_mode;
        self.target.reconfigure(surface_cfg) catch |err| {
            if (err == error.UnsupportedPresentMode) return error.UnsupportedPresentMode;
            return mapFrameError(err);
        };
    }
    self.cfg = new_cfg;
}

pub fn supportedPresentModes(self: *const Renderer) gpu.Context.PresentModes {
    return self.target.supportedPresentModes();
}

pub fn beginFrame(self: *Renderer) *DrawList {
    self.draw_list.reset();
    return &self.draw_list;
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

pub fn endFrame(self: *Renderer, glyph_builder: *text.GlyphBuilder, content_scale: f32) EndFrameError!void {
    self.draw(self.group.device, &self.group.shared, &self.draw_list, glyph_builder, content_scale) catch |err| return mapEndFrameError(err);
}

fn mapEndFrameError(err: anyerror) EndFrameError {
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

fn draw(self: *Renderer, device: *gpu_impl.Device, shared: *Shared, dl: *const DrawList, glyph_builder: *text.GlyphBuilder, content_scale: f32) !void {
    var frame_ctx = try self.target.beginFrame();
    const upload_slot: usize = @intCast(frame_ctx.upload_slot);
    std.debug.assert(upload_slot < self.frame_uploads.len);
    const upload = &self.frame_uploads[upload_slot];

    try self.syncGlyphBuilder(device, shared, glyph_builder);

    const has_work = !dl.isEmpty() and shared.atlas_texture.isReady();
    if (!has_work) {
        var pass = try frame_ctx.beginRenderPass(.{ .color_attachment = .{ .clear_color = self.cfg.clear_color } });
        pass.end();
        try self.submitFrame(&frame_ctx);
        return;
    }

    self.updateViewport(upload, content_scale);
    const sizes = try uploadFrameData(device, shared, upload, dl);
    const use_linear_target = shared.linear_pipeline != null;
    if (use_linear_target) try self.ensureLinearTarget(device, shared);

    var pass = if (use_linear_target)
        try frame_ctx.beginRenderPass(.{ .color_attachment = .{ .clear_color = self.cfg.clear_color, .target = &self.linear_target.? } })
    else
        try frame_ctx.beginRenderPass(.{ .color_attachment = .{ .clear_color = self.cfg.clear_color } });

    const target_size = self.target.size();
    const phys_w = target_size.width;
    const phys_h = target_size.height;
    var current_clip: Clip.State = .{};
    var current_texture: ?Shared.TextureId = null;
    var current_kind: ?DrawList.CommandKind = null;
    var clip_initialized = false;
    var layer_it = dl.layers_dirty.iterator(.{});
    while (layer_it.next()) |z| {
        const r = dl.layer_ranges[z];
        for (dl.layer_cmds.items[r.start .. r.start + r.len]) |cmd| {
            if (current_kind != cmd.kind) {
                bindKind(shared, &self.text_curveband_bg, &pass, upload, cmd.kind, sizes, use_linear_target);
                current_texture = null;
                current_kind = cmd.kind;
            }
            if (cmd.kind != .text and cmd.texture != current_texture) {
                try bindTextureForCommand(device, shared, &pass, cmd.texture);
                current_texture = cmd.texture;
            }
            if (!clip_initialized or !current_clip.scissorEql(cmd.clip)) {
                applyClip(&pass, cmd.clip.scissor, content_scale, phys_w, phys_h);
                current_clip = cmd.clip;
                clip_initialized = true;
            }
            dispatchCommand(&pass, cmd);
        }
    }
    pass.end();

    if (use_linear_target) try self.compositeLinearTarget(shared, &frame_ctx, upload, content_scale);
    try self.submitFrame(&frame_ctx);
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
    const target_size = self.target.size();
    const logical_w: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(target_size.width)) / content_scale)));
    const logical_h: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(target_size.height)) / content_scale)));
    const phys_w_u = target_size.width;
    const phys_h_u = target_size.height;

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

fn uploadFrameData(device: *gpu_impl.Device, shared: *Shared, uploads: *FrameUploads, dl: *const DrawList) !FrameSizes {
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
    try uploads.ensureClipNodeCapacity(device, &shared.pipeline, &shared.instance_pipeline, &shared.text_pipeline, clip_nodes.len * @sizeOf(Clip.Node));
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
    shared: *Shared,
    text_curveband_bg: *gpu_impl.BindGroup,
    pass: *gpu_impl.RenderPass,
    uploads: *FrameUploads,
    kind: DrawList.CommandKind,
    sizes: FrameSizes,
    linear_target: bool,
) void {
    switch (kind) {
        .vertex => {
            const pipeline = if (linear_target) &shared.linear_pipeline.? else &shared.pipeline;
            pass.bindPipeline(pipeline);
            pass.setBindGroup(0, &uploads.vertex_uniform_bg);
            pass.setBindGroup(1, &shared.atlas_texture_bg);
            pass.setBindGroup(2, &uploads.vertex_clip_bg);
            pass.setVertexBuffer(0, &uploads.vertex_buf, 0, sizes.verts_bytes);
            pass.setIndexBuffer(&uploads.index_buf, 0, sizes.indices_bytes);
        },
        .instance => {
            const pipeline = if (linear_target) &shared.linear_instance_pipeline.? else &shared.instance_pipeline;
            pass.bindPipeline(pipeline);
            pass.setBindGroup(0, &uploads.instance_uniform_bg);
            pass.setBindGroup(1, &shared.atlas_texture_bg);
            pass.setBindGroup(2, &uploads.instance_clip_bg);
            pass.setVertexBuffer(0, &uploads.instance_buf, 0, sizes.insts_bytes);
            pass.setIndexBuffer(&shared.unit_index_buf, 0, 6 * @sizeOf(u32));
        },
        .text => {
            const pipeline = if (linear_target) &shared.linear_text_pipeline.? else &shared.text_pipeline;
            pass.bindPipeline(pipeline);
            pass.setBindGroup(0, &uploads.text_uniform_bg);
            pass.setBindGroup(1, text_curveband_bg);
            pass.setBindGroup(2, &uploads.text_clip_bg);
            pass.setVertexBuffer(0, &uploads.text_vertex_buf, 0, sizes.tverts_bytes);
            pass.setIndexBuffer(&uploads.text_index_buf, 0, sizes.tindices_bytes);
        },
    }
}

fn bindTextureForCommand(device: *gpu_impl.Device, shared: *Shared, pass: *gpu_impl.RenderPass, texture: ?Shared.TextureId) !void {
    pass.setBindGroup(1, try shared.bindGroupForTexture(device, texture));
}

fn ensureLinearTarget(self: *Renderer, device: *gpu_impl.Device, shared: *Shared) !void {
    const target_size = self.target.size();
    const w = target_size.width;
    const h = target_size.height;
    if (self.linear_target != null and self.linear_target_width == w and self.linear_target_height == h) return;

    try self.target.waitForCompletion();
    if (self.linear_target_bg) |*bg| bg.deinit();
    self.linear_target_bg = null;
    if (self.linear_target) |*t| t.deinit();
    self.linear_target = null;

    self.linear_target = try device.createTexture(.{
        .width = w,
        .height = h,
        .format = .rgba8,
        .usage = .{ .texture_binding = true, .render_attachment = true },
        .label = "linear_ui_target",
    });
    self.linear_target_width = w;
    self.linear_target_height = h;

    self.linear_target_bg = try device.createBindGroup(.{
        .label = "linear_ui_target_bg",
        .pipeline = &shared.instance_pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &self.linear_target.? } },
            .{ .binding = 1, .resource = .{ .sampler = &shared.linear_sampler.? } },
        },
    });
}

fn compositeLinearTarget(self: *Renderer, shared: *Shared, frame_ctx: *gpu_impl.Frame.Context, uploads: *FrameUploads, content_scale: f32) !void {
    const target_size = self.target.size();
    const logical_w: f32 = @as(f32, @floatFromInt(target_size.width)) / content_scale;
    const logical_h: f32 = @as(f32, @floatFromInt(target_size.height)) / content_scale;
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

    var pass = try frame_ctx.beginRenderPass(.{ .color_attachment = .{ .clear_color = self.cfg.clear_color } });
    pass.bindPipeline(&shared.instance_pipeline);
    pass.setBindGroup(0, &uploads.instance_uniform_bg);
    pass.setBindGroup(1, &self.linear_target_bg.?);
    pass.setBindGroup(2, &uploads.instance_clip_bg);
    pass.setVertexBuffer(0, &uploads.composite_instance_buf, 0, @sizeOf(gpu.Instance));
    pass.setIndexBuffer(&shared.unit_index_buf, 0, 6 * @sizeOf(u32));
    pass.setScissorRect(0, 0, target_size.width, target_size.height);
    pass.drawIndexed(6, 1, 0, 0, 0);
    pass.end();
}

fn applyClip(pass: *gpu_impl.RenderPass, clip_rect: ?math.Rect, content_scale: f32, phys_w: u32, phys_h: u32) void {
    const vw: f32 = @floatFromInt(phys_w);
    const vh: f32 = @floatFromInt(phys_h);
    if (sanitizeClip(clip_rect)) |clip| {
        const cx = @min(vw, @max(0, clip[0] * content_scale));
        const cy = @min(vh, @max(0, clip[1] * content_scale));
        const cw = @max(0, @min(clip[2] * content_scale, vw - cx));
        const ch = @max(0, @min(clip[3] * content_scale, vh - cy));
        pass.setScissorRect(@intFromFloat(cx), @intFromFloat(cy), @intFromFloat(cw), @intFromFloat(ch));
    } else {
        pass.setScissorRect(0, 0, phys_w, phys_h);
    }
}

fn dispatchCommand(pass: *gpu_impl.RenderPass, cmd: DrawList.Command) void {
    switch (cmd.kind) {
        .vertex => pass.drawIndexed(cmd.count, 1, cmd.offset, 0, 0),
        .instance => pass.drawIndexed(6, cmd.count, 0, 0, cmd.offset),
        .text => pass.drawIndexed(cmd.count, 1, cmd.offset, 0, 0),
    }
}

fn syncGlyphBuilder(self: *Renderer, device: *gpu_impl.Device, shared: *Shared, gb: *text.GlyphBuilder) !void {
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
        });
    }
    if (needed_band_h > self.band_tex_height) {
        new_band_h = std.math.ceilPowerOfTwo(u32, needed_band_h) catch needed_band_h;
        new_band_texture = try device.createTexture(.{
            .width = BAND_TEX_WIDTH,
            .height = new_band_h,
            .format = .rgba32u,
            .usage = .{ .texture_binding = true, .copy_dst = true },
        });
    }

    if (new_curve_texture != null or new_band_texture != null) {
        const curve_for_bg = if (new_curve_texture) |*t| t else &self.curve_texture;
        const band_for_bg = if (new_band_texture) |*t| t else &self.band_texture;
        new_curveband_bg = try device.createBindGroup(.{
            .label = "text_curveband_bg",
            .pipeline = &shared.text_pipeline,
            .layout_index = 1,
            .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = curve_for_bg } },
                .{ .binding = 1, .resource = .{ .texture_view = band_for_bg } },
            },
        });

        try self.target.waitForCompletion();

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
            r.y0,
            r.y1,
        );
    }
    if (gb.bandDirtyRange()) |r| {
        try uploadDirtyRows(
            text.GlyphBuilder.BandTexel,
            self.allocator,
            &self.band_texture,
            gb.band_data.items,
            BAND_TEX_WIDTH,
            r.y0,
            r.y1,
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

fn sanitizeClip(c: ?math.Rect) ?[4]f32 {
    const rect = c orelse return null;
    const v = [4]f32{ rect.x(), rect.y(), rect.w(), rect.h() };
    for (v) |f| if (!std.math.isFinite(f)) return null;
    return v;
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
