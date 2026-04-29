const std = @import("std");
const gpu = @import("gpu");
const GPUBackend = @import("gpu_backend").Backend;
const text = @import("text");
const Window = @import("window").Window;
const builtin = @import("builtin");

const DrawList = @import("DrawList.zig");

const INIT_VERTEX_BYTES = 256 * 1024;
const INIT_INSTANCE_BYTES = 64 * 1024;
const INIT_INDEX_COUNT = 64 * 1024;
const INIT_TEXT_VERTEX_BYTES = 128 * 1024;
const INIT_TEXT_INDEX_COUNT = 16 * 1024;
const MAX_TEXTURES = 16;

const CURVE_TEX_WIDTH: u32 = text.GlyphBuilder.TEXTURE_WIDTH;
const BAND_TEX_WIDTH: u32 = text.GlyphBuilder.TEXTURE_WIDTH;
const INITIAL_TEX_HEIGHT: u32 = 256;

pub const Config = struct {
    present_mode: gpu.Context.PresentMode = .fifo,
    gpu_backend: GPUBackend = .preferred(),

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
};

allocator: std.mem.Allocator,
window: Window,
cfg: Config,
ctx: gpu.Context,
pipeline: gpu.Pipeline,
instance_pipeline: gpu.Pipeline,
text_pipeline: gpu.Pipeline,
vertex_buf: gpu.Buffer,
index_buf: gpu.Buffer,
instance_buf: gpu.Buffer,
unit_index_buf: gpu.Buffer,
text_vertex_buf: gpu.Buffer,
text_index_buf: gpu.Buffer,
atlas_texture: gpu.Texture,
atlas_sampler: gpu.Sampler,
curve_texture: gpu.Texture,
band_texture: gpu.Texture,
curve_tex_height: u32,
band_tex_height: u32,
frame: gpu.Frame,
cached_vp_width: u32 = 0,
cached_vp_height: u32 = 0,
registered_textures: [MAX_TEXTURES]?TextureBinding = .{null} ** MAX_TEXTURES,

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

    const pipeline = try ctx.createPipeline(.{ .kind = .vertex });
    errdefer pipeline.deinit();

    const instance_pipeline = try ctx.createPipeline(.{ .kind = .instance });
    errdefer instance_pipeline.deinit();

    const text_pipeline = try ctx.createPipeline(.{ .kind = .text });
    errdefer text_pipeline.deinit();

    const vertex_buf = try ctx.createBuffer(INIT_VERTEX_BYTES, .{ .vertex = true, .copy_dst = true });
    errdefer vertex_buf.deinit();

    const instance_buf = try ctx.createBuffer(INIT_INSTANCE_BYTES, .{ .vertex = true, .copy_dst = true });
    errdefer instance_buf.deinit();

    const text_vertex_buf = try ctx.createBuffer(INIT_TEXT_VERTEX_BYTES, .{ .vertex = true, .copy_dst = true });
    errdefer text_vertex_buf.deinit();

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

    const dummy_pixel = [_]u8{0};
    try atlas_texture.write(&dummy_pixel, 1, 0, 0, 1, 1, null);

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

    const index_buf = try ctx.createBuffer(INIT_INDEX_COUNT * @sizeOf(u32), .{ .index = true, .copy_dst = true });
    errdefer index_buf.deinit();

    const text_index_buf = try ctx.createBuffer(INIT_TEXT_INDEX_COUNT * @sizeOf(u32), .{ .index = true, .copy_dst = true });
    errdefer text_index_buf.deinit();

    const unit_index_buf = try ctx.createBuffer(6 * @sizeOf(u32), .{ .index = true, .copy_dst = true });
    errdefer unit_index_buf.deinit();
    const unit_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    unit_index_buf.load(u32, &unit_indices);

    return .{
        .allocator = allocator,
        .window = window,
        .cfg = cfg,
        .ctx = ctx,
        .pipeline = pipeline,
        .instance_pipeline = instance_pipeline,
        .text_pipeline = text_pipeline,
        .vertex_buf = vertex_buf,
        .index_buf = index_buf,
        .instance_buf = instance_buf,
        .unit_index_buf = unit_index_buf,
        .text_vertex_buf = text_vertex_buf,
        .text_index_buf = text_index_buf,
        .atlas_texture = atlas_texture,
        .atlas_sampler = atlas_sampler,
        .curve_texture = curve_texture,
        .band_texture = band_texture,
        .curve_tex_height = INITIAL_TEX_HEIGHT,
        .band_tex_height = INITIAL_TEX_HEIGHT,
        .frame = try ctx.createFrame(),
    };
}

pub fn deinit(self: *Renderer) void {
    self.frame.deinit();
    for (&self.registered_textures) |*entry| {
        if (entry.*) |*reg| {
            reg.texture.deinit();
            reg.sampler.deinit();
        }
    }
    self.pipeline.deinit();
    self.instance_pipeline.deinit();
    self.text_pipeline.deinit();
    self.vertex_buf.deinit();
    self.index_buf.deinit();
    self.instance_buf.deinit();
    self.unit_index_buf.deinit();
    self.text_vertex_buf.deinit();
    self.text_index_buf.deinit();
    self.atlas_texture.deinit();
    self.atlas_sampler.deinit();
    self.curve_texture.deinit();
    self.band_texture.deinit();
    self.ctx.deinit();
}

pub fn createTexture(self: *Renderer, width: u32, height: u32, format: gpu.Texture.Format) !u32 {
    const id = for (0..MAX_TEXTURES) |i| {
        if (self.registered_textures[i] == null) break @as(u32, @intCast(i));
    } else return error.MaxTexturesReached;
    const sampler = try self.ctx.createSampler(.{ .mag_filter = .linear, .min_filter = .linear });
    const texture = try self.ctx.createTexture(.{
        .width = width,
        .height = height,
        .format = format,
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .sampler = &sampler,
    });
    self.registered_textures[id] = .{ .texture = texture, .sampler = sampler };
    return id;
}

pub fn writeTexture(self: *Renderer, id: u32, data: [*]const u8, len: usize, width: u32, height: u32, bytes_per_row: ?u32) !void {
    if (id >= MAX_TEXTURES) return error.InvalidTextureId;
    const reg = self.registered_textures[id] orelse return error.InvalidTextureId;
    try reg.texture.write(data, len, 0, 0, width, height, bytes_per_row);
}

pub fn destroyTexture(self: *Renderer, id: u32) !void {
    if (id >= MAX_TEXTURES) return error.InvalidTextureId;
    const reg = &(self.registered_textures[id] orelse return error.InvalidTextureId);
    reg.texture.deinit();
    reg.sampler.deinit();
    self.registered_textures[id] = null;
}

pub fn resize(self: *Renderer, width: u32, height: u32) !void {
    if (width == self.ctx.cfg.window_width and height == self.ctx.cfg.window_height) return;
    try self.frame.prepareResize();
    try self.ctx.resize(width, height);
}

pub fn reconfigure(self: *Renderer, new_cfg: Config) !void {
    if (std.meta.eql(new_cfg, self.cfg)) return;
    try new_cfg.validate();

    const allocator = self.allocator;
    const window = self.window;

    try self.frame.waitForCompletion();
    self.deinit();
    self.* = try Renderer.init(allocator, window, new_cfg);
}

pub fn draw(
    self: *Renderer,
    dl: *const DrawList,
    glyph_builder: *text.GlyphBuilder,
    content_scale: f32,
) !void {
    if (dl.cmds.items.len == 0) return;

    try self.frame.waitForFence();

    try self.syncGlyphBuilder(glyph_builder);
    self.pipeline.bindTexture(&self.atlas_texture, &self.atlas_sampler);
    self.instance_pipeline.bindTexture(&self.atlas_texture, &self.atlas_sampler);
    if (!self.atlas_texture.isReady()) return;

    // Vertex coords are in logical pixels; surface/scissor are in physical pixels.
    // The GPU rasterizer stretches NDC to the physical surface, so we feed the
    // shader the logical viewport size for correct pixel->NDC mapping.
    const logical_w: u32 = @intFromFloat(@as(f32, @floatFromInt(self.ctx.cfg.window_width)) / content_scale);
    const logical_h: u32 = @intFromFloat(@as(f32, @floatFromInt(self.ctx.cfg.window_height)) / content_scale);
    if (logical_w != self.cached_vp_width or logical_h != self.cached_vp_height) {
        self.pipeline.updateViewport(logical_w, logical_h);
        self.instance_pipeline.updateViewport(logical_w, logical_h);
        self.text_pipeline.updateViewport(logical_w, logical_h);
        self.cached_vp_width = logical_w;
        self.cached_vp_height = logical_h;
    }

    const verts = dl.vertices.items;
    const verts_bytes = verts.len * @sizeOf(gpu.Vertex);
    if (verts.len > 0) {
        try ensureBufferCapacity(&self.vertex_buf, verts_bytes);
        self.vertex_buf.load(gpu.Vertex, verts);
    }
    const insts = dl.instances.items;
    const insts_bytes = insts.len * @sizeOf(gpu.Instance);
    if (insts.len > 0) {
        try ensureBufferCapacity(&self.instance_buf, insts_bytes);
        self.instance_buf.load(gpu.Instance, insts);
    }
    if (dl.indices.items.len > 0) {
        try ensureBufferCapacity(&self.index_buf, dl.indices.items.len * @sizeOf(u32));
        self.index_buf.load(u32, dl.indices.items);
    }
    const tverts = dl.text_vertices.items;
    const tverts_bytes = tverts.len * @sizeOf(gpu.SlugVertex);
    if (tverts.len > 0) {
        try ensureBufferCapacity(&self.text_vertex_buf, tverts_bytes);
        self.text_vertex_buf.load(gpu.SlugVertex, tverts);
    }
    if (dl.text_indices.items.len > 0) {
        try ensureBufferCapacity(&self.text_index_buf, dl.text_indices.items.len * @sizeOf(u32));
        self.text_index_buf.load(u32, dl.text_indices.items);
    }

    var pass = try self.frame.beginRenderPass(.{ .color_attachment = .{} });

    const vw: f32 = @floatFromInt(self.ctx.cfg.window_width);
    const vh: f32 = @floatFromInt(self.ctx.cfg.window_height);
    var current_clip: ?[4]f32 = .{ 0, 0, 0, 0 };
    var current_texture: ?u32 = null;
    var current_kind: ?DrawList.CommandKind = null;
    for (dl.cmds.items) |cmd| {
        if (current_kind != cmd.kind) {
            switch (cmd.kind) {
                .vertex => {
                    pass.bindPipeline(&self.pipeline);
                    pass.setVertexBuffer(0, &self.vertex_buf, 0, verts_bytes);
                    pass.setIndexBuffer(&self.index_buf, 0, dl.indices.items.len * @sizeOf(u32));
                },
                .instance => {
                    pass.bindPipeline(&self.instance_pipeline);
                    pass.setVertexBuffer(0, &self.instance_buf, 0, insts_bytes);
                    pass.setIndexBuffer(&self.unit_index_buf, 0, 6 * @sizeOf(u32));
                },
                .text => {
                    pass.bindPipeline(&self.text_pipeline);
                    pass.setVertexBuffer(0, &self.text_vertex_buf, 0, tverts_bytes);
                    pass.setIndexBuffer(&self.text_index_buf, 0, dl.text_indices.items.len * @sizeOf(u32));
                },
            }
            current_texture = null;
            current_kind = cmd.kind;
        }
        if (cmd.kind != .text and cmd.texture != current_texture) {
            if (cmd.texture) |tex_id| {
                if (self.registered_textures[tex_id]) |*reg| {
                    self.pipeline.bindTexture(&reg.texture, &reg.sampler);
                    self.instance_pipeline.bindTexture(&reg.texture, &reg.sampler);
                }
            } else {
                self.pipeline.bindTexture(&self.atlas_texture, &self.atlas_sampler);
                self.instance_pipeline.bindTexture(&self.atlas_texture, &self.atlas_sampler);
            }
            pass.rebindTextureSet();
            current_texture = cmd.texture;
        }
        if (!std.meta.eql(current_clip, cmd.clip_rect)) {
            if (cmd.clip_rect) |clip| {
                const cx = @min(vw, @max(0, clip[0] * content_scale));
                const cy = @min(vh, @max(0, clip[1] * content_scale));
                const cw = @max(0, @min(clip[2] * content_scale, vw - cx));
                const ch = @max(0, @min(clip[3] * content_scale, vh - cy));
                current_clip = cmd.clip_rect;
                if (cw == 0 or ch == 0) continue;
                pass.setScissorRect(@intFromFloat(cx), @intFromFloat(cy), @intFromFloat(cw), @intFromFloat(ch));
            } else {
                pass.setScissorRect(0, 0, self.ctx.cfg.window_width, self.ctx.cfg.window_height);
                current_clip = cmd.clip_rect;
            }
        }
        switch (cmd.kind) {
            .vertex => pass.drawIndexed(cmd.count, 1, cmd.offset, 0, 0),
            .instance => pass.drawIndexed(6, cmd.count, 0, 0, cmd.offset),
            .text => pass.drawIndexed(cmd.count, 1, cmd.offset, 0, 0),
        }
    }
    pass.end();
    try self.frame.submit();
}

fn syncGlyphBuilder(self: *Renderer, gb: *text.GlyphBuilder) !void {
    const needed_curve_h = gb.curveTextureHeight();
    const needed_band_h = gb.bandTextureHeight();

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
        gb.curve_dirty_min_y = 0;
        gb.curve_dirty_max_y_excl = needed_curve_h;
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
        gb.band_dirty_min_y = 0;
        gb.band_dirty_max_y_excl = needed_band_h;
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

    self.text_pipeline.bindCurveBand(&self.curve_texture, &self.band_texture);
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

fn ensureBufferCapacity(buf: *gpu.Buffer, required: usize) !void {
    const current_size = buf.getSize();
    if (required <= current_size) return;
    const new_size = @max(required, current_size + current_size / 2);
    try buf.resize(new_size);
}
