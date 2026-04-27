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
const MAX_TEXTURES = 16;

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
vertex_buf: gpu.Buffer,
index_buf: gpu.Buffer,
instance_buf: gpu.Buffer,
unit_index_buf: gpu.Buffer,
atlas_texture: gpu.Texture,
atlas_sampler: gpu.Sampler,
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

    const vertex_buf = try ctx.createBuffer(INIT_VERTEX_BYTES, .{ .vertex = true, .copy_dst = true });
    errdefer vertex_buf.deinit();

    const instance_buf = try ctx.createBuffer(INIT_INSTANCE_BYTES, .{ .vertex = true, .copy_dst = true });
    errdefer instance_buf.deinit();

    const atlas_texture = try ctx.createTexture(.{
        .width = 1024,
        .height = 1024,
        .format = .r8,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer atlas_texture.deinit();

    const atlas_sampler = try ctx.createSampler(.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
    });
    errdefer atlas_sampler.deinit();

    const index_buf = try ctx.createBuffer(INIT_INDEX_COUNT * @sizeOf(u32), .{ .index = true, .copy_dst = true });
    errdefer index_buf.deinit();

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
        .vertex_buf = vertex_buf,
        .index_buf = index_buf,
        .instance_buf = instance_buf,
        .unit_index_buf = unit_index_buf,
        .atlas_texture = atlas_texture,
        .atlas_sampler = atlas_sampler,
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
    self.vertex_buf.deinit();
    self.index_buf.deinit();
    self.instance_buf.deinit();
    self.unit_index_buf.deinit();
    self.atlas_texture.deinit();
    self.atlas_sampler.deinit();
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

pub fn draw(self: *Renderer, dl: *const DrawList, atlas: *text.Atlas, content_scale: f32) !void {
    if (dl.cmds.items.len == 0) return;

    try self.frame.waitForFence();

    try self.syncAtlas(atlas);
    if (!self.atlas_texture.isReady()) return;

    // Vertex coords are in logical pixels; surface/scissor are in physical pixels.
    // The GPU rasterizer stretches NDC to the physical surface, so we feed the
    // shader the logical viewport size for correct pixel->NDC mapping.
    const logical_w: u32 = @intFromFloat(@as(f32, @floatFromInt(self.ctx.cfg.window_width)) / content_scale);
    const logical_h: u32 = @intFromFloat(@as(f32, @floatFromInt(self.ctx.cfg.window_height)) / content_scale);
    if (logical_w != self.cached_vp_width or logical_h != self.cached_vp_height) {
        self.pipeline.updateViewport(logical_w, logical_h);
        self.instance_pipeline.updateViewport(logical_w, logical_h);
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
            }
            current_texture = null;
            current_kind = cmd.kind;
        }
        if (cmd.texture != current_texture) {
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
                const cx = @max(0, clip[0] * content_scale);
                const cy = @max(0, clip[1] * content_scale);
                pass.setScissorRect(@intFromFloat(cx), @intFromFloat(cy), @intFromFloat(@max(0, @min(clip[2] * content_scale, vw - cx))), @intFromFloat(@max(0, @min(clip[3] * content_scale, vh - cy))));
            } else {
                pass.setScissorRect(0, 0, self.ctx.cfg.window_width, self.ctx.cfg.window_height);
            }

            current_clip = cmd.clip_rect;
        }
        switch (cmd.kind) {
            .vertex => pass.drawIndexed(cmd.count, 1, cmd.offset, 0, 0),
            .instance => pass.drawIndexed(6, cmd.count, 0, 0, cmd.offset),
        }
    }
    pass.end();
    try self.frame.submit();
}

fn syncAtlas(self: *Renderer, atlas: *text.Atlas) !void {
    if (atlas.isDirty()) {
        const y0 = atlas.dirty_min_y;
        const y1 = atlas.dirty_max_y_excl;
        const row_h = y1 - y0;
        const stride = atlas.width;
        const offset = y0 * stride;
        const len = row_h * stride;
        try self.atlas_texture.write(atlas.bitmap.ptr + offset, len, 0, y0, atlas.width, row_h, null);
        atlas.markClean();
    }
    // Ensure current_texture_ds is valid for the initial bindPipeline call
    self.pipeline.bindTexture(&self.atlas_texture, &self.atlas_sampler);
    self.instance_pipeline.bindTexture(&self.atlas_texture, &self.atlas_sampler);
}

fn ensureBufferCapacity(buf: *gpu.Buffer, required: usize) !void {
    const current_size = buf.getSize();
    if (required <= current_size) return;
    const new_size = @max(required, current_size + current_size / 2);
    try buf.resize(new_size);
}
