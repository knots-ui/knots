const std = @import("std");
const gpu = @import("gpu");
const GPUBackend = @import("gpu_backend").Backend;
const text = @import("text");
const Window = @import("window").Window;
const math = @import("math");
const builtin = @import("builtin");

const DrawList = @import("DrawList.zig");
const Clip = @import("Clip.zig");
const pipelines = @import("pipelines.zig");
const FrameUploads = @import("FrameUploads.zig");

const TEX_INDEX_BITS: u5 = 16;
const TEX_INDEX_MASK: u32 = (@as(u32, 1) << TEX_INDEX_BITS) - 1;
const PIXEL_TEXTURE_TTL_FRAMES: u32 = 2;
const PixelTextureKey = u64;

const CURVE_TEX_WIDTH: u32 = text.GlyphBuilder.TEXTURE_WIDTH;
const BAND_TEX_WIDTH: u32 = text.GlyphBuilder.TEXTURE_WIDTH;
const INITIAL_TEX_HEIGHT: u32 = 256;

pub const Config = struct {
    present_mode: gpu.Context.PresentMode = .fifo,
    gpu_backend: GPUBackend = .preferred(),
    clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },

    pub const ValidationError = error{
        BackendNotAvailable,
        UnsupportedPresentMode,
    };

    pub fn validate(cfg: Config) ValidationError!void {
        if (!cfg.gpu_backend.isAvailable()) return error.BackendNotAvailable;

        switch (builtin.os.tag) {
            .macos => switch (cfg.present_mode) {
                // Metal/MoltenVK only supports fifo and immediate.
                .fifo_relaxed, .mailbox => return error.UnsupportedPresentMode,
                .fifo, .immediate => {},
            },
            .emscripten => switch (cfg.present_mode) {
                .fifo => {},
                else => return error.UnsupportedPresentMode,
            },
            else => {},
        }
    }
};

const TextureBinding = struct {
    texture: gpu.Texture,
    sampler: gpu.Sampler,
    width: u32,
    height: u32,
    format: gpu.Texture.Format,
};

const TextureSlot = struct {
    binding: ?TextureBinding,
    bg: ?gpu.BindGroup = null,
    gen: u16,
};

const PixelTextureCacheEntry = struct {
    texture_id: ?u32 = null,
    width: u32 = 0,
    height: u32 = 0,
    format: gpu.Texture.Format = .rgba8,
    data_ptr: usize = 0,
    len: usize = 0,
    bytes_per_row: ?u32 = null,
    version: u64 = 0,
    last_seen: u32 = 0,
};

const PixelTextureIdContext = struct {
    pub fn hash(_: PixelTextureIdContext, id: PixelTextureKey) u64 {
        return id;
    }

    pub fn eql(_: PixelTextureIdContext, a: PixelTextureKey, b: PixelTextureKey) bool {
        return a == b;
    }
};

const PixelTextureCache = std.HashMapUnmanaged(
    PixelTextureKey,
    PixelTextureCacheEntry,
    PixelTextureIdContext,
    std.hash_map.default_max_load_percentage,
);

allocator: std.mem.Allocator,
window: Window,
cfg: Config,
ctx: gpu.Context,
pipeline: gpu.Pipeline,
instance_pipeline: gpu.Pipeline,
text_pipeline: gpu.Pipeline,
linear_pipeline: ?gpu.Pipeline = null,
linear_instance_pipeline: ?gpu.Pipeline = null,
linear_text_pipeline: ?gpu.Pipeline = null,

atlas_texture_bg: gpu.BindGroup,
text_curveband_bg: gpu.BindGroup,

frame_uploads: []FrameUploads,
unit_index_buf: gpu.Buffer,
atlas_texture: gpu.Texture,
atlas_sampler: gpu.Sampler,
linear_target: ?gpu.Texture = null,
linear_target_bg: ?gpu.BindGroup = null,
linear_sampler: ?gpu.Sampler = null,
linear_target_width: u32 = 0,
linear_target_height: u32 = 0,
curve_texture: gpu.Texture,
band_texture: gpu.Texture,
curve_tex_height: u32,
band_tex_height: u32,
frame: gpu.Frame,
texture_slots: std.ArrayList(TextureSlot),
free_slot_indices: std.ArrayList(u32),
pixel_texture_cache: PixelTextureCache,
pixel_texture_scratch: std.ArrayList(PixelTextureKey),
pixel_texture_frame: u32,
draw_list: DrawList,

const Renderer = @This();

pub fn init(allocator: std.mem.Allocator, window: Window, cfg: Config) !Renderer {
    try cfg.validate();

    const fb = window.getFramebufferSize();
    const ctx_cfg = gpu.Context.Config{
        .window_width = fb.width,
        .window_height = fb.height,
        .present_mode = cfg.present_mode,
    };

    const ctx = try cfg.gpu_backend.init(allocator, window.getWindowHandle(), ctx_cfg);
    errdefer ctx.deinit();

    const srgb_surface = ctx.surfaceIsSrgb();

    const pipeline = try ctx.createPipeline(pipelines.primitivesDesc(cfg.gpu_backend, .vertex, srgb_surface));
    errdefer pipeline.deinit();

    const instance_pipeline = try ctx.createPipeline(pipelines.primitivesDesc(cfg.gpu_backend, .instance, srgb_surface));
    errdefer instance_pipeline.deinit();

    const text_pipeline = try ctx.createPipeline(pipelines.slugDesc(cfg.gpu_backend, srgb_surface));
    errdefer text_pipeline.deinit();

    const use_linear_target = cfg.gpu_backend == .wgpu and !srgb_surface;
    const linear_pipeline: ?gpu.Pipeline = if (use_linear_target)
        try ctx.createPipeline(pipelines.linearTargetPrimitivesDesc(cfg.gpu_backend, .vertex))
    else
        null;
    errdefer if (linear_pipeline) |p| p.deinit();

    const linear_instance_pipeline: ?gpu.Pipeline = if (use_linear_target)
        try ctx.createPipeline(pipelines.linearTargetPrimitivesDesc(cfg.gpu_backend, .instance))
    else
        null;
    errdefer if (linear_instance_pipeline) |p| p.deinit();

    const linear_text_pipeline: ?gpu.Pipeline = if (use_linear_target)
        try ctx.createPipeline(pipelines.linearTargetSlugDesc(cfg.gpu_backend))
    else
        null;
    errdefer if (linear_text_pipeline) |p| p.deinit();

    const atlas_texture = try ctx.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .r8,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer atlas_texture.deinit();

    const atlas_sampler = try ctx.createSampler(.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
    });
    errdefer atlas_sampler.deinit();

    const linear_sampler: ?gpu.Sampler = if (use_linear_target)
        try ctx.createSampler(.{ .mag_filter = .nearest, .min_filter = .nearest })
    else
        null;
    errdefer if (linear_sampler) |s| s.deinit();

    const dummy_pixel = [_]u8{0};
    try atlas_texture.write(&dummy_pixel, 1, 0, 0, 1, 1, null);

    const atlas_texture_bg = try ctx.createBindGroup(.{
        .label = "atlas_texture_bg",
        .pipeline = &pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &atlas_texture } },
            .{ .binding = 1, .resource = .{ .sampler = &atlas_sampler } },
        },
    });
    errdefer atlas_texture_bg.deinit();

    const curve_texture = try ctx.createTexture(.{
        .width = CURVE_TEX_WIDTH,
        .height = INITIAL_TEX_HEIGHT,
        .format = .rgba32f,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer curve_texture.deinit();

    const band_texture = try ctx.createTexture(.{
        .width = BAND_TEX_WIDTH,
        .height = INITIAL_TEX_HEIGHT,
        .format = .rgba32u,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer band_texture.deinit();

    const text_curveband_bg = try ctx.createBindGroup(.{
        .label = "text_curveband_bg",
        .pipeline = &text_pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &curve_texture } },
            .{ .binding = 1, .resource = .{ .texture_view = &band_texture } },
        },
    });
    errdefer text_curveband_bg.deinit();

    const unit_index_buf = try ctx.createBuffer(6 * @sizeOf(u32), .{ .index = true, .copy_dst = true });
    errdefer unit_index_buf.deinit();
    const unit_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    unit_index_buf.load(u32, &unit_indices);

    var frame = try ctx.createFrame();
    errdefer frame.deinit();

    const uploads = try allocator.alloc(FrameUploads, @intCast(frame.uploadSlotCount()));
    errdefer allocator.free(uploads);
    var upload_count: usize = 0;
    errdefer for (uploads[0..upload_count]) |*u| u.deinit();
    for (uploads) |*u| {
        u.* = try .init(&ctx, &pipeline, &instance_pipeline, &text_pipeline);
        upload_count += 1;
    }

    return .{
        .allocator = allocator,
        .window = window,
        .cfg = cfg,
        .ctx = ctx,
        .pipeline = pipeline,
        .instance_pipeline = instance_pipeline,
        .text_pipeline = text_pipeline,
        .linear_pipeline = linear_pipeline,
        .linear_instance_pipeline = linear_instance_pipeline,
        .linear_text_pipeline = linear_text_pipeline,
        .atlas_texture_bg = atlas_texture_bg,
        .text_curveband_bg = text_curveband_bg,
        .frame_uploads = uploads,
        .unit_index_buf = unit_index_buf,
        .atlas_texture = atlas_texture,
        .atlas_sampler = atlas_sampler,
        .linear_sampler = linear_sampler,
        .curve_texture = curve_texture,
        .band_texture = band_texture,
        .curve_tex_height = INITIAL_TEX_HEIGHT,
        .band_tex_height = INITIAL_TEX_HEIGHT,
        .frame = frame,
        .draw_list = .init(allocator),
        .texture_slots = .empty,
        .free_slot_indices = .empty,
        .pixel_texture_cache = .empty,
        .pixel_texture_scratch = .empty,
        .pixel_texture_frame = 0,
    };
}

pub fn deinit(self: *Renderer) void {
    self.draw_list.deinit();
    self.frame.deinit();

    self.atlas_texture_bg.deinit();
    self.text_curveband_bg.deinit();
    for (self.frame_uploads) |*u| u.deinit();
    self.allocator.free(self.frame_uploads);

    for (self.texture_slots.items) |*slot| {
        if (slot.bg) |bg| bg.deinit();
        if (slot.binding) |*reg| {
            reg.texture.deinit();
            reg.sampler.deinit();
        }
    }
    self.texture_slots.deinit(self.allocator);
    self.free_slot_indices.deinit(self.allocator);
    self.pixel_texture_cache.deinit(self.allocator);
    self.pixel_texture_scratch.deinit(self.allocator);
    self.pipeline.deinit();
    self.instance_pipeline.deinit();
    self.text_pipeline.deinit();
    if (self.linear_pipeline) |p| p.deinit();
    if (self.linear_instance_pipeline) |p| p.deinit();
    if (self.linear_text_pipeline) |p| p.deinit();
    if (self.linear_target_bg) |bg| bg.deinit();
    if (self.linear_target) |t| t.deinit();
    if (self.linear_sampler) |s| s.deinit();
    self.unit_index_buf.deinit();
    self.atlas_texture.deinit();
    self.atlas_sampler.deinit();
    self.curve_texture.deinit();
    self.band_texture.deinit();
    self.ctx.deinit();
}

pub fn createTexture(self: *Renderer, width: u32, height: u32, format: gpu.Texture.Format) !u32 {
    const sampler = try self.ctx.createSampler(.{ .mag_filter = .linear, .min_filter = .linear });
    errdefer sampler.deinit();
    const texture = try self.ctx.createTexture(.{
        .width = width,
        .height = height,
        .format = format,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer texture.deinit();

    const binding: TextureBinding = .{
        .texture = texture,
        .sampler = sampler,
        .width = width,
        .height = height,
        .format = format,
    };

    if (self.free_slot_indices.pop()) |idx| {
        self.texture_slots.items[idx].binding = binding;
        return packTextureId(idx, self.texture_slots.items[idx].gen);
    }

    const idx: u32 = @intCast(self.texture_slots.items.len);
    if (idx > TEX_INDEX_MASK) return error.MaxTexturesReached;
    try self.texture_slots.append(self.allocator, .{ .binding = binding, .gen = 0 });
    return packTextureId(idx, 0);
}

pub fn writeTexture(self: *Renderer, id: u32, data: [*]const u8, len: usize, width: u32, height: u32, bytes_per_row: ?u32) !void {
    const reg = (try self.lookupTexture(id)) orelse return error.InvalidTextureId;
    if (width > reg.width or height > reg.height) return error.InvalidTextureWrite;
    const required = try requiredTextureBytes(width, height, bytesPerGpuPixel(reg.format), bytes_per_row);
    if (len < required) return error.InvalidTextureWrite;
    try reg.texture.write(data, len, 0, 0, width, height, bytes_per_row);
}

pub fn destroyTexture(self: *Renderer, id: u32) !void {
    const idx = id & TEX_INDEX_MASK;
    if (idx >= self.texture_slots.items.len) return error.InvalidTextureId;
    const slot = &self.texture_slots.items[idx];
    if ((id >> TEX_INDEX_BITS) != slot.gen) return error.InvalidTextureId;
    if (slot.binding) |*reg| {
        try self.free_slot_indices.ensureUnusedCapacity(self.allocator, 1);
        if (slot.bg) |bg| bg.deinit();
        slot.bg = null;
        reg.texture.deinit();
        reg.sampler.deinit();
        slot.binding = null;
        slot.gen +%= 1;
        self.free_slot_indices.appendAssumeCapacity(idx);
    } else return error.InvalidTextureId;
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
) !u32 {
    const required = try requiredTextureBytes(width, height, bytesPerGpuPixel(format), bytes_per_row);
    if (data.len < required) return error.InvalidTextureWrite;

    const data_ptr = @intFromPtr(data.ptr);
    const gop = try self.pixel_texture_cache.getOrPutContext(self.allocator, id, .{});
    if (!gop.found_existing) gop.value_ptr.* = .{};
    errdefer _ = if (!gop.found_existing) self.pixel_texture_cache.remove(id);

    const entry = gop.value_ptr;
    entry.last_seen = self.pixel_texture_frame;

    const needs_recreate =
        entry.texture_id == null or
        entry.width != width or
        entry.height != height or
        entry.format != format;

    var texture_id = entry.texture_id;
    var new_texture_id: ?u32 = null;
    errdefer if (new_texture_id) |tex| self.destroyTexture(tex) catch {};

    if (needs_recreate) {
        const tex = try self.createTexture(width, height, format);
        new_texture_id = tex;
        texture_id = tex;
    }

    const needs_upload =
        needs_recreate or
        entry.data_ptr != data_ptr or
        entry.len != data.len or
        entry.bytes_per_row != bytes_per_row or
        entry.version != version;

    if (needs_upload) {
        try self.writeTexture(texture_id.?, data.ptr, data.len, width, height, bytes_per_row);
    }

    if (needs_recreate) {
        if (entry.texture_id) |old_tex| try self.destroyTexture(old_tex);
        entry.texture_id = new_texture_id.?;
        entry.width = width;
        entry.height = height;
        entry.format = format;
        new_texture_id = null;
    }

    if (needs_upload) {
        entry.data_ptr = data_ptr;
        entry.len = data.len;
        entry.bytes_per_row = bytes_per_row;
        entry.version = version;
    }

    return entry.texture_id.?;
}

fn lookupTexture(self: *Renderer, id: u32) !?*TextureBinding {
    const idx = id & TEX_INDEX_MASK;
    if (idx >= self.texture_slots.items.len) return error.InvalidTextureId;
    const slot = &self.texture_slots.items[idx];
    if ((id >> TEX_INDEX_BITS) != slot.gen) return error.InvalidTextureId;
    if (slot.binding) |*b| return b;
    return null;
}

fn packTextureId(idx: u32, gen: u16) u32 {
    return (@as(u32, gen) << TEX_INDEX_BITS) | (idx & TEX_INDEX_MASK);
}

fn bytesPerGpuPixel(format: gpu.Texture.Format) usize {
    return switch (format) {
        .r8 => 1,
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .rgba32f, .rgba32u => 16,
    };
}

fn requiredTextureBytes(width: u32, height: u32, bpp: usize, bytes_per_row: ?u32) !usize {
    if (width == 0 or height == 0) return error.InvalidTextureWrite;

    const row_bytes = std.math.mul(usize, @as(usize, width), bpp) catch
        return error.InvalidTextureWrite;

    if (bytes_per_row) |stride_u32| {
        const stride: usize = stride_u32;
        if (stride < row_bytes) return error.InvalidTextureWrite;

        const prefix = std.math.mul(usize, @as(usize, height - 1), stride) catch
            return error.InvalidTextureWrite;
        return std.math.add(usize, prefix, row_bytes) catch
            return error.InvalidTextureWrite;
    }

    return std.math.mul(usize, row_bytes, @as(usize, height)) catch
        return error.InvalidTextureWrite;
}

pub fn resize(self: *Renderer, width: u32, height: u32) !void {
    if (width == self.ctx.cfg.window_width and height == self.ctx.cfg.window_height) return;
    self.frame.prepareResize();
    try self.ctx.resize(width, height);
}

/// Tears down all GPU state and re-creates the renderer with the new config.
/// All textures registered via `createTexture` are dropped and their ids invalidated.
pub fn reconfigure(self: *Renderer, new_cfg: Config) !void {
    if (std.meta.eql(new_cfg, self.cfg)) return;
    try new_cfg.validate();

    const allocator = self.allocator;
    const window = self.window;

    try self.frame.waitForCompletion();
    self.deinit();
    self.* = try Renderer.init(allocator, window, new_cfg);
}

pub fn beginFrame(self: *Renderer) *DrawList {
    self.draw_list.reset();
    return &self.draw_list;
}

pub fn endFrame(self: *Renderer, glyph_builder: *text.GlyphBuilder, content_scale: f32) !void {
    try self.draw(&self.draw_list, glyph_builder, content_scale);
    try self.sweepPixelTextureCache();
    self.pixel_texture_frame +%= 1;
}

fn sweepPixelTextureCache(self: *Renderer) !void {
    self.pixel_texture_scratch.clearRetainingCapacity();

    var it = self.pixel_texture_cache.iterator();
    while (it.next()) |kv| {
        if (self.pixel_texture_frame -% kv.value_ptr.last_seen >= PIXEL_TEXTURE_TTL_FRAMES) {
            try self.pixel_texture_scratch.append(self.allocator, kv.key_ptr.*);
        }
    }

    for (self.pixel_texture_scratch.items) |id| {
        const entry = self.pixel_texture_cache.get(id) orelse continue;
        if (entry.texture_id) |tex| try self.destroyTexture(tex);
        _ = self.pixel_texture_cache.remove(id);
    }
}

const FrameSizes = struct {
    verts_bytes: usize,
    insts_bytes: usize,
    indices_bytes: usize,
    tverts_bytes: usize,
    tindices_bytes: usize,
};

fn draw(self: *Renderer, dl: *const DrawList, glyph_builder: *text.GlyphBuilder, content_scale: f32) !void {
    var frame_ctx = try self.frame.begin();
    const upload_slot: usize = @intCast(frame_ctx.upload_slot);
    std.debug.assert(upload_slot < self.frame_uploads.len);
    const upload = &self.frame_uploads[upload_slot];

    try self.syncGlyphBuilder(glyph_builder);

    const has_work = !dl.isEmpty() and self.atlas_texture.isReady();
    if (!has_work) {
        var pass = try frame_ctx.beginRenderPass(.{ .color_attachment = .{ .clear_color = self.cfg.clear_color } });
        pass.end();
        try frame_ctx.submit();
        return;
    }

    self.updateViewport(upload, content_scale);
    const sizes = try self.uploadFrameData(upload, dl);
    const use_linear_target = self.linear_pipeline != null;
    if (use_linear_target) try self.ensureLinearTarget();

    var pass = if (use_linear_target)
        try frame_ctx.beginRenderPass(.{ .color_attachment = .{ .clear_color = self.cfg.clear_color, .target = &self.linear_target.? } })
    else
        try frame_ctx.beginRenderPass(.{ .color_attachment = .{ .clear_color = self.cfg.clear_color } });

    const phys_w = self.ctx.cfg.window_width;
    const phys_h = self.ctx.cfg.window_height;
    var current_clip: Clip.State = .{};
    var current_texture: ?u32 = null;
    var current_kind: ?DrawList.CommandKind = null;
    var clip_initialized = false;
    var layer_it = dl.layers_dirty.iterator(.{});
    while (layer_it.next()) |z| {
        const r = dl.layer_ranges[z];
        for (dl.layer_cmds.items[r.start .. r.start + r.len]) |cmd| {
            if (current_kind != cmd.kind) {
                self.bindKind(&pass, upload, cmd.kind, sizes, use_linear_target);
                current_texture = null;
                current_kind = cmd.kind;
            }
            if (cmd.kind != .text and cmd.texture != current_texture) {
                try self.bindTextureForCommand(&pass, cmd.texture);
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

    if (use_linear_target) try self.compositeLinearTarget(&frame_ctx, upload, content_scale);
    try frame_ctx.submit();
}

fn updateViewport(self: *Renderer, uploads: *FrameUploads, content_scale: f32) void {
    const logical_w: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.ctx.cfg.window_width)) / content_scale)));
    const logical_h: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(self.ctx.cfg.window_height)) / content_scale)));
    const phys_w_u = self.ctx.cfg.window_width;
    const phys_h_u = self.ctx.cfg.window_height;

    const w_f: f32 = @floatFromInt(logical_w);
    const h_f: f32 = @floatFromInt(logical_h);
    const viewport: pipelines.ViewportUniform = .{ w_f, h_f };
    uploads.vertex_uniform_buf.load(pipelines.ViewportUniform, &.{viewport});
    uploads.instance_uniform_buf.load(pipelines.ViewportUniform, &.{viewport});

    const phys_w: f32 = @floatFromInt(phys_w_u);
    const phys_h: f32 = @floatFromInt(phys_h_u);
    const u = pipelines.computeSlugUniforms(w_f, h_f, phys_w, phys_h, self.ctx.clipSpaceYDown());
    uploads.text_uniform_buf.load(pipelines.SlugUniforms, &.{u});
}

fn uploadFrameData(self: *Renderer, uploads: *FrameUploads, dl: *const DrawList) !FrameSizes {
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
    try uploads.ensureClipNodeCapacity(&self.ctx, &self.pipeline, &self.instance_pipeline, &self.text_pipeline, clip_nodes.len * @sizeOf(Clip.Node));
    uploads.clip_node_buf.load(Clip.Node, clip_nodes);
    return .{
        .verts_bytes = verts.len * @sizeOf(gpu.Vertex),
        .insts_bytes = insts.len * @sizeOf(gpu.Instance),
        .indices_bytes = dl.indices.items.len * @sizeOf(u32),
        .tverts_bytes = tverts.len * @sizeOf(gpu.SlugVertex),
        .tindices_bytes = dl.text_indices.items.len * @sizeOf(u32),
    };
}

fn bindKind(self: *Renderer, pass: *gpu.RenderPass, uploads: *FrameUploads, kind: DrawList.CommandKind, sizes: FrameSizes, linear_target: bool) void {
    switch (kind) {
        .vertex => {
            const pipeline = if (linear_target) &self.linear_pipeline.? else &self.pipeline;
            pass.bindPipeline(pipeline);
            pass.setBindGroup(0, &uploads.vertex_uniform_bg);
            pass.setBindGroup(1, &self.atlas_texture_bg);
            pass.setBindGroup(2, &uploads.vertex_clip_bg);
            pass.setVertexBuffer(0, &uploads.vertex_buf, 0, sizes.verts_bytes);
            pass.setIndexBuffer(&uploads.index_buf, 0, sizes.indices_bytes);
        },
        .instance => {
            const pipeline = if (linear_target) &self.linear_instance_pipeline.? else &self.instance_pipeline;
            pass.bindPipeline(pipeline);
            pass.setBindGroup(0, &uploads.instance_uniform_bg);
            pass.setBindGroup(1, &self.atlas_texture_bg);
            pass.setBindGroup(2, &uploads.instance_clip_bg);
            pass.setVertexBuffer(0, &uploads.instance_buf, 0, sizes.insts_bytes);
            pass.setIndexBuffer(&self.unit_index_buf, 0, 6 * @sizeOf(u32));
        },
        .text => {
            const pipeline = if (linear_target) &self.linear_text_pipeline.? else &self.text_pipeline;
            pass.bindPipeline(pipeline);
            pass.setBindGroup(0, &uploads.text_uniform_bg);
            pass.setBindGroup(1, &self.text_curveband_bg);
            pass.setBindGroup(2, &uploads.text_clip_bg);
            pass.setVertexBuffer(0, &uploads.text_vertex_buf, 0, sizes.tverts_bytes);
            pass.setIndexBuffer(&uploads.text_index_buf, 0, sizes.tindices_bytes);
        },
    }
}

fn bindTextureForCommand(self: *Renderer, pass: *gpu.RenderPass, texture: ?u32) !void {
    if (texture) |tex_id| {
        const idx = tex_id & TEX_INDEX_MASK;
        if (idx >= self.texture_slots.items.len) {
            pass.setBindGroup(1, &self.atlas_texture_bg);
            return;
        }
        const slot = &self.texture_slots.items[idx];
        if ((tex_id >> TEX_INDEX_BITS) != slot.gen or slot.binding == null) {
            pass.setBindGroup(1, &self.atlas_texture_bg);
            return;
        }
        const bg = try self.getOrCreateTextureBg(slot);
        pass.setBindGroup(1, &bg);
    } else {
        pass.setBindGroup(1, &self.atlas_texture_bg);
    }
}

fn ensureLinearTarget(self: *Renderer) !void {
    const w = self.ctx.cfg.window_width;
    const h = self.ctx.cfg.window_height;
    if (self.linear_target != null and self.linear_target_width == w and self.linear_target_height == h) return;

    try self.frame.waitForCompletion();
    if (self.linear_target_bg) |bg| bg.deinit();
    self.linear_target_bg = null;
    if (self.linear_target) |t| t.deinit();
    self.linear_target = null;

    self.linear_target = try self.ctx.createTexture(.{
        .width = w,
        .height = h,
        .format = .rgba8,
        .usage = .{ .texture_binding = true, .render_attachment = true },
        .label = "linear_ui_target",
    });
    self.linear_target_width = w;
    self.linear_target_height = h;

    self.linear_target_bg = try self.ctx.createBindGroup(.{
        .label = "linear_ui_target_bg",
        .pipeline = &self.instance_pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &self.linear_target.? } },
            .{ .binding = 1, .resource = .{ .sampler = &self.linear_sampler.? } },
        },
    });
}

fn compositeLinearTarget(self: *Renderer, frame_ctx: *gpu.Frame.Context, uploads: *FrameUploads, content_scale: f32) !void {
    const logical_w: f32 = @as(f32, @floatFromInt(self.ctx.cfg.window_width)) / content_scale;
    const logical_h: f32 = @as(f32, @floatFromInt(self.ctx.cfg.window_height)) / content_scale;
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
    pass.bindPipeline(&self.instance_pipeline);
    pass.setBindGroup(0, &uploads.instance_uniform_bg);
    pass.setBindGroup(1, &self.linear_target_bg.?);
    pass.setBindGroup(2, &uploads.instance_clip_bg);
    pass.setVertexBuffer(0, &uploads.composite_instance_buf, 0, @sizeOf(gpu.Instance));
    pass.setIndexBuffer(&self.unit_index_buf, 0, 6 * @sizeOf(u32));
    pass.setScissorRect(0, 0, self.ctx.cfg.window_width, self.ctx.cfg.window_height);
    pass.drawIndexed(6, 1, 0, 0, 0);
    pass.end();
}

fn getOrCreateTextureBg(self: *Renderer, slot: *TextureSlot) !gpu.BindGroup {
    if (slot.bg) |bg| return bg;
    const reg = &slot.binding.?;
    const bg = try self.ctx.createBindGroup(.{
        .label = "user_texture_bg",
        .pipeline = &self.pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &reg.texture } },
            .{ .binding = 1, .resource = .{ .sampler = &reg.sampler } },
        },
    });
    slot.bg = bg;
    return bg;
}

fn applyClip(pass: *gpu.RenderPass, clip_rect: ?math.Rect, content_scale: f32, phys_w: u32, phys_h: u32) void {
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

fn dispatchCommand(pass: *gpu.RenderPass, cmd: DrawList.Command) void {
    switch (cmd.kind) {
        .vertex => pass.drawIndexed(cmd.count, 1, cmd.offset, 0, 0),
        .instance => pass.drawIndexed(6, cmd.count, 0, 0, cmd.offset),
        .text => pass.drawIndexed(cmd.count, 1, cmd.offset, 0, 0),
    }
}

fn syncGlyphBuilder(self: *Renderer, gb: *text.GlyphBuilder) !void {
    const needed_curve_h = gb.curveTextureHeight();
    const needed_band_h = gb.bandTextureHeight();

    var curveband_dirty = false;

    if (needed_curve_h > self.curve_tex_height) {
        try self.frame.waitForCompletion();
        self.curve_texture.deinit();
        const new_h = std.math.ceilPowerOfTwo(u32, needed_curve_h) catch needed_curve_h;
        self.curve_texture = try self.ctx.createTexture(.{
            .width = CURVE_TEX_WIDTH,
            .height = new_h,
            .format = .rgba32f,
            .usage = .{ .texture_binding = true, .copy_dst = true },
        });
        self.curve_tex_height = new_h;
        gb.markCurveDirtyTo(needed_curve_h);
        curveband_dirty = true;
    }
    if (needed_band_h > self.band_tex_height) {
        try self.frame.waitForCompletion();
        self.band_texture.deinit();
        const new_h = std.math.ceilPowerOfTwo(u32, needed_band_h) catch needed_band_h;
        self.band_texture = try self.ctx.createTexture(.{
            .width = BAND_TEX_WIDTH,
            .height = new_h,
            .format = .rgba32u,
            .usage = .{ .texture_binding = true, .copy_dst = true },
        });
        self.band_tex_height = new_h;
        gb.markBandDirtyTo(needed_band_h);
        curveband_dirty = true;
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

    if (curveband_dirty) {
        self.text_curveband_bg.deinit();
        self.text_curveband_bg = try self.ctx.createBindGroup(.{
            .label = "text_curveband_bg",
            .pipeline = &self.text_pipeline,
            .layout_index = 1,
            .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = &self.curve_texture } },
                .{ .binding = 1, .resource = .{ .texture_view = &self.band_texture } },
            },
        });
    }
}

fn uploadDirtyRows(
    comptime T: type,
    allocator: std.mem.Allocator,
    texture: *gpu.Texture,
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

fn ensureBufferCapacity(buf: *gpu.Buffer, required: usize) !void {
    const current_size = buf.getSize();
    if (required <= current_size) return;
    const new_size = @max(required, current_size + current_size / 2);
    try buf.resize(new_size);
}

fn ensureAndLoad(buf: *gpu.Buffer, comptime T: type, items: []const T) !void {
    if (items.len == 0) return;
    try ensureBufferCapacity(buf, items.len * @sizeOf(T));
    buf.load(T, items);
}
