const std = @import("std");
const gpu = @import("gpu");
const gpu_impl = @import("gpu_impl");
const Packet = @import("render").Packet;
const GlyphAtlas = @import("render").GlyphAtlas;
const GlyphAtlasCache = @import("GlyphAtlasCache.zig");
const math = @import("math");

const Command = @import("render").Command;
const TextureSource = @import("render").TextureSource;
const Clip = @import("render").Clip;
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

const CURVE_TEX_WIDTH: u32 = GlyphAtlas.width;
const BAND_TEX_WIDTH: u32 = GlyphAtlas.width;
const INITIAL_TEX_HEIGHT: u32 = 256;

allocator: std.mem.Allocator,
context: *Context,
text_curveband_bg: gpu_impl.BindGroup,
frame_uploads: []FrameUploads,
curve_texture: gpu_impl.Texture,
band_texture: gpu_impl.Texture,
curve_tex_height: u32,
band_tex_height: u32,
pixel_textures: std.AutoHashMapUnmanaged(PixelTextureKey, PixelTextureEntry),
pixel_texture_scratch: std.ArrayList(PixelTextureKey),
retired_resources: std.ArrayList(RetiredResource),
upload_slots_live: u8 = 0,
frame_index: u64,
prepare_generation: u64 = 0,
glyph_upload: GlyphAtlasCache = .{},
const Painter = @This();
pub const slots_max: u32 = 8;
pub const textures_max: u32 = 4096;
const retired_resources_max: u32 = 2 * textures_max;
pub const PrepareOptions = struct {
    width: u32,
    height: u32,
    content_scale: f32,
    upload_slot: u32,
    frame_context: gpu_impl.Frame.Context,
    linear_target: bool,
};
/// Borrowed until the next prepare. Complete work using the chosen upload slot
/// before preparation; submit encoded work before preparing another packet.
/// Replaced textures are released as upload slots complete. An unrecycled slot
/// retains those resources until `destroyAfterWait`.
pub const Prepared = struct { owner: *const Painter, generation: u64, packet: *const Packet, options: PrepareOptions, sizes: FrameSizes };
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
const RetiredGlyphResources = struct {
    bind_group: gpu_impl.BindGroup,
    curve_texture: ?gpu_impl.Texture,
    band_texture: ?gpu_impl.Texture,
};
const RetiredValue = union(enum) {
    pixel_texture: *Texture,
    glyph_resources: RetiredGlyphResources,
};
const RetiredResource = struct {
    slots_pending: u8,
    value: RetiredValue,
};

pub fn create(allocator: std.mem.Allocator, context: *Context, upload_slots: u32) !*Painter {
    std.debug.assert(upload_slots > 0);
    std.debug.assert(upload_slots <= slots_max);
    const device = context.device;
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

    const uploads = try allocator.alloc(FrameUploads, upload_slots);
    errdefer allocator.free(uploads);
    var upload_count: u32 = 0;
    errdefer for (uploads[0..upload_count]) |*u| u.deinit();
    for (uploads) |*u| {
        u.* = try .init(context);
        upload_count += 1;
    }

    const self = try allocator.create(Painter);
    self.* = .{
        .allocator = allocator,
        .context = context,
        .text_curveband_bg = text_curveband_bg,
        .frame_uploads = uploads,
        .curve_texture = curve_texture,
        .band_texture = band_texture,
        .curve_tex_height = INITIAL_TEX_HEIGHT,
        .band_tex_height = INITIAL_TEX_HEIGHT,
        .pixel_textures = .empty,
        .pixel_texture_scratch = .empty,
        .retired_resources = .empty,
        .frame_index = 0,
    };
    return self;
}
/// The host must complete GPU work before destroying resources.
pub fn destroyAfterWait(self: *Painter) void {
    std.debug.assert(self.frame_uploads.len > 0);
    std.debug.assert(self.frame_uploads.len <= slots_max);
    std.debug.assert(self.retired_resources.items.len <= retired_resources_max);
    for (self.retired_resources.items) |resource| destroyRetiredResource(resource.value);
    self.retired_resources.deinit(self.allocator);
    var iterator = self.pixel_textures.valueIterator();
    var remaining: u32 = @intCast(self.pixel_textures.count());
    while (remaining > 0) : (remaining -= 1) iterator.next().?.texture.destroyAfterWait();
    self.pixel_textures.deinit(self.allocator);
    self.pixel_texture_scratch.deinit(self.allocator);
    self.text_curveband_bg.deinit();
    for (self.frame_uploads) |*upload| upload.deinit();
    self.allocator.free(self.frame_uploads);
    self.curve_texture.deinit();
    self.band_texture.deinit();
    self.allocator.destroy(self);
}
pub fn prepare(self: *Painter, packet: *const Packet, options: *const PrepareOptions) !Prepared {
    std.debug.assert(options.width > 0);
    std.debug.assert(options.height > 0);
    std.debug.assert(options.upload_slot < self.frame_uploads.len);
    std.debug.assert(std.math.isFinite(options.content_scale));
    std.debug.assert(options.content_scale > 0);
    if (packet.commands().len > Packet.commands_max) return error.TooManyDrawCommands;
    try packet.validateExtensions(.knots);
    if (options.linear_target) {
        if (self.context.linear_pipeline == null) return error.UnsupportedTarget;
    }
    if (self.prepare_generation == std.math.maxInt(u64)) return error.GenerationExhausted;
    // The host has completed previous GPU work using this upload slot.
    self.retireUploadSlot(options.upload_slot);
    self.upload_slots_live |= uploadSlotMask(options.upload_slot);
    self.prepare_generation += 1;
    try self.preparePixelTextures(packet);
    const upload = &self.frame_uploads[options.upload_slot];
    upload.resetCustom(options.frame_context);
    if (packet.glyphAtlas()) |atlas| try self.glyph_upload.sync(&atlas, self, uploadGlyphAtlas);
    updateViewport(upload, options);
    const sizes = try uploadFrameData(self.context, upload, packet);
    try self.sweepPixelTextures();
    return .{ .owner = self, .generation = self.prepare_generation, .packet = packet, .options = options.*, .sizes = sizes };
}
/// Encode into a compatible host pass without ending, submitting or presenting.
/// The host restores pass state it needs after this call. Target format and depth
/// must match Context pipelines, or its linear RGBA8 pipelines when selected.
pub fn encode(self: *Painter, prepared: *const Prepared, pass: *gpu_impl.RenderPass) !void {
    if (prepared.owner != self) return error.InvalidPreparedFrame;
    if (prepared.generation != self.prepare_generation) return error.InvalidPreparedFrame;
    const dl = prepared.packet;
    const options = prepared.options;
    std.debug.assert(options.upload_slot < self.frame_uploads.len);
    std.debug.assert(dl.commands().len <= Packet.commands_max);
    const context = self.context;
    const upload = &self.frame_uploads[options.upload_slot];
    const content_scale = options.content_scale;
    const phys_w = options.width;
    const phys_h = options.height;
    const sizes = prepared.sizes;
    const use_linear_target = options.linear_target;
    pass.setViewport(0, 0, @floatFromInt(phys_w), @floatFromInt(phys_h));
    var state: DrawState = .{};
    for (dl.commands()) |cmd| {
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
                .context = .{ .inner = context, .draw_format = if (use_linear_target) .rgba8 else context.device.surfaceFormat() },
                .frame = .{ .inner = upload },
                .pass = .{ .inner = pass },
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
            try custom.paint.callback(custom.paint.user_data, &public_context);

            pass.setViewport(0, 0, @floatFromInt(phys_w), @floatFromInt(phys_h));
            state = .{};
            continue;
        }

        if (!context.atlas.isReady()) continue;

        if (state.kind != kind) {
            bindKind(context, &self.text_curveband_bg, pass, upload, kind, sizes, use_linear_target);
            state.texture = null;
            state.kind = kind;
        }
        const texture = switch (cmd.payload) {
            .vertex => |value| self.textureForSource(value.texture),
            .instance => |value| self.textureForSource(value.texture),
            .text => null,
            .custom_draw => unreachable,
        };
        if (kind != .text and texture != state.texture) {
            pass.setBindGroup(1, if (texture) |value| &value.bind_group else &context.atlas.bind_group);
            state.texture = texture;
        }
        if (state.clip == null or !state.clip.?.scissorEql(cmd.clip)) {
            applyClip(pass, cmd.clip.scissor, content_scale, phys_w, phys_h);
            state.clip = cmd.clip;
        }
        switch (cmd.payload) {
            .vertex => |value| pass.drawIndexed(value.count, 1, value.offset, 0, 0),
            .instance => |value| pass.drawIndexed(6, value.count, 0, 0, value.offset),
            .text => |value| pass.drawIndexed(6, value.count, 0, 0, value.offset),
            .custom_draw => unreachable,
        }
    }
}

fn uploadSlotMask(slot: u32) u8 {
    std.debug.assert(slot < slots_max);
    return @as(u8, 1) << @intCast(slot);
}

fn retireUploadSlot(self: *Painter, slot: u32) void {
    const mask = uploadSlotMask(slot);
    std.debug.assert(self.retired_resources.items.len <= retired_resources_max);
    self.upload_slots_live &= ~mask;
    var index: u32 = 0;
    while (index < self.retired_resources.items.len) {
        const resource = &self.retired_resources.items[index];
        resource.slots_pending &= ~mask;
        if (resource.slots_pending == 0) {
            const completed = self.retired_resources.swapRemove(index);
            destroyRetiredResource(completed.value);
        } else {
            index += 1;
        }
    }
}

fn reserveRetiredResources(self: *Painter, count: u32) !void {
    std.debug.assert(count <= retired_resources_max);
    std.debug.assert(self.retired_resources.items.len <= retired_resources_max);
    if (self.retired_resources.items.len > retired_resources_max - count)
        return error.TooManyRetiredResources;
    try self.retired_resources.ensureUnusedCapacity(self.allocator, count);
}

fn destroyRetiredResource(value: RetiredValue) void {
    switch (value) {
        .pixel_texture => |texture| texture.destroyAfterWait(),
        .glyph_resources => |resources| {
            var bind_group = resources.bind_group;
            bind_group.deinit();
            if (resources.curve_texture) |texture| {
                var old = texture;
                old.deinit();
            }
            if (resources.band_texture) |texture| {
                var old = texture;
                old.deinit();
            }
        },
    }
}

fn textureFromPixels(
    self: *Painter,
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
            try self.reserveRetiredResources(1);
            const replacement = try self.context.createTexture(width, height, format);
            errdefer replacement.destroyAfterWait();
            try replacement.write(data, width, height, bytes_per_row);
            const old_texture = entry.texture;
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
            self.retired_resources.appendAssumeCapacity(.{
                .slots_pending = self.upload_slots_live,
                .value = .{ .pixel_texture = old_texture },
            });
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

    if (self.pixel_textures.count() == textures_max) return error.TooManyTextures;
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

const FrameSizes = struct {
    verts_bytes: usize,
    insts_bytes: usize,
    indices_bytes: usize,
    text_instances_bytes: usize,
};

const DrawState = struct {
    clip: ?Clip.State = null,
    texture: ?*const Texture = null,
    kind: ?Command.Kind = null,
};

fn preparePixelTextures(self: *Painter, draw_list: *const Packet) !void {
    for (draw_list.commands()) |command| {
        const source = switch (command.payload) {
            .vertex => |value| value.texture,
            .instance => |value| value.texture,
            .text, .custom_draw => continue,
        };
        switch (source) {
            .atlas => {},
            .texture => |handle| {
                const texture: *const Texture = @ptrCast(@alignCast(handle.pointer));
                if (texture.device != self.context.device) return error.IncompatibleTextureDevice;
            },
            .pixels => |pixels| {
                _ = try self.textureFromPixels(
                    pixels.key,
                    pixels.data,
                    pixels.width,
                    pixels.height,
                    pixels.format,
                    pixels.bytes_per_row,
                    pixels.version,
                    pixels.force_upload,
                );
            },
        }
    }
}

fn textureForSource(self: *Painter, source: TextureSource) ?*const Texture {
    return switch (source) {
        .atlas => null,
        .texture => |handle| @ptrCast(@alignCast(handle.pointer)),
        .pixels => |pixels| self.pixel_textures.getPtr(pixels.key).?.texture,
    };
}

fn sweepPixelTextures(self: *Painter) !void {
    self.pixel_texture_scratch.clearRetainingCapacity();
    var it = self.pixel_textures.iterator();
    var remaining: u32 = @intCast(self.pixel_textures.count());
    while (remaining > 0) : (remaining -= 1) {
        const entry = it.next().?;
        if (self.frame_index -% entry.value_ptr.last_seen >= PIXEL_TEXTURE_TTL_FRAMES)
            try self.pixel_texture_scratch.append(self.allocator, entry.key_ptr.*);
    }
    if (self.pixel_texture_scratch.items.len > 0) {
        try self.reserveRetiredResources(@intCast(self.pixel_texture_scratch.items.len));
        for (self.pixel_texture_scratch.items) |key| {
            const removed = self.pixel_textures.fetchRemove(key).?;
            self.retired_resources.appendAssumeCapacity(.{
                .slots_pending = self.upload_slots_live,
                .value = .{ .pixel_texture = removed.value.texture },
            });
        }
    }

    self.frame_index +%= 1;
}

fn updateViewport(uploads: *FrameUploads, options: *const PrepareOptions) void {
    const content_scale = options.content_scale;
    const phys_w_u = options.width;
    const phys_h_u = options.height;
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

fn uploadFrameData(context: *Context, uploads: *FrameUploads, dl: *const Packet) !FrameSizes {
    const verts = dl.primitiveVertices();
    const insts = dl.instances();
    const text_instances = dl.textInstances();
    const empty_clip_nodes = [_]Clip.Node{Clip.Node.empty};
    const clip_nodes = if (dl.clipNodes().len > 0) dl.clipNodes() else empty_clip_nodes[0..];
    try ensureAndLoad(&uploads.vertex_buf, gpu.Vertex, verts);
    try ensureAndLoad(&uploads.instance_buf, gpu.Instance, insts);
    try ensureAndLoad(&uploads.index_buf, u32, dl.primitiveIndices());
    try ensureAndLoad(&uploads.text_instance_buf, gpu.SlugInstance, text_instances);
    try uploads.ensureClipNodeCapacity(context, clip_nodes.len * @sizeOf(Clip.Node));
    uploads.clip_node_buf.load(Clip.Node, clip_nodes);
    return .{
        .verts_bytes = verts.len * @sizeOf(gpu.Vertex),
        .insts_bytes = insts.len * @sizeOf(gpu.Instance),
        .indices_bytes = dl.primitiveIndices().len * @sizeOf(u32),
        .text_instances_bytes = text_instances.len * @sizeOf(gpu.SlugInstance),
    };
}

fn bindKind(
    context: *Context,
    text_curveband_bg: *gpu_impl.BindGroup,
    pass: *gpu_impl.RenderPass,
    uploads: *FrameUploads,
    kind: Command.Kind,
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
            pass.setVertexBuffer(0, &uploads.text_instance_buf, 0, sizes.text_instances_bytes);
            pass.setIndexBuffer(&context.unit_index_buf, 0, 6 * @sizeOf(u32));
        },
        .custom_draw => unreachable,
    }
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

fn uploadGlyphAtlas(self: *Painter, atlas: *const GlyphAtlas) !void {
    atlas.validate();
    const device = self.context.device;
    const context = self.context;
    const needed_curve_h: u32 = @intCast(std.math.divCeil(u64, atlas.curve.len, GlyphAtlas.row_bytes) catch unreachable);
    const needed_band_h: u32 = @intCast(std.math.divCeil(u64, atlas.band.len, GlyphAtlas.row_bytes) catch unreachable);
    std.debug.assert(needed_curve_h <= GlyphAtlas.width);
    std.debug.assert(needed_band_h <= GlyphAtlas.width);

    var curve_row_start: u32 = 0;
    var band_row_start: u32 = 0;
    if (self.glyph_upload.canUploadDelta(atlas)) {
        curve_row_start = atlas.curve_row_start;
        band_row_start = atlas.band_row_start;
    }

    var new_curve_texture: ?gpu_impl.Texture = null;
    var new_band_texture: ?gpu_impl.Texture = null;
    var new_curve_h = self.curve_tex_height;
    var new_band_h = self.band_tex_height;
    var new_curveband_bg: ?gpu_impl.BindGroup = null;
    errdefer if (new_curve_texture) |*t| t.deinit();
    errdefer if (new_band_texture) |*t| t.deinit();
    errdefer if (new_curveband_bg) |*bg| bg.deinit();

    if (needed_curve_h > self.curve_tex_height) {
        curve_row_start = 0;
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
        band_row_start = 0;
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
        try self.reserveRetiredResources(1);
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

        const old_curveband_bg = self.text_curveband_bg;
        self.text_curveband_bg = new_curveband_bg.?;
        new_curveband_bg = null;

        var old_curve_texture: ?gpu_impl.Texture = null;
        var old_band_texture: ?gpu_impl.Texture = null;

        if (new_curve_texture) |tex| {
            old_curve_texture = self.curve_texture;
            self.curve_texture = tex;
            self.curve_tex_height = new_curve_h;
            new_curve_texture = null;
        }
        if (new_band_texture) |tex| {
            old_band_texture = self.band_texture;
            self.band_texture = tex;
            self.band_tex_height = new_band_h;
            new_band_texture = null;
        }
        self.retired_resources.appendAssumeCapacity(.{
            .slots_pending = self.upload_slots_live,
            .value = .{ .glyph_resources = .{
                .bind_group = old_curveband_bg,
                .curve_texture = old_curve_texture,
                .band_texture = old_band_texture,
            } },
        });
    }

    try uploadGlyphPlane(self.allocator, &self.curve_texture, atlas.curve, curve_row_start);
    try uploadGlyphPlane(self.allocator, &self.band_texture, atlas.band, band_row_start);
}

fn uploadGlyphPlane(allocator: std.mem.Allocator, texture: anytype, bytes: []const u8, row_start: u32) !void {
    std.debug.assert(bytes.len <= GlyphAtlas.plane_bytes_max);
    std.debug.assert(bytes.len % GlyphAtlas.texel_bytes == 0);
    const rows_total: u32 = @intCast(std.math.divCeil(u64, bytes.len, GlyphAtlas.row_bytes) catch unreachable);
    std.debug.assert(row_start <= rows_total);
    if (row_start == rows_total) return;
    const offset: u32 = row_start * GlyphAtlas.row_bytes;
    const rows_full: u32 = @intCast(@divFloor(bytes.len, GlyphAtlas.row_bytes));
    const bytes_full: u32 = rows_full * GlyphAtlas.row_bytes;
    if (row_start < rows_full) {
        try texture.write(bytes[offset..].ptr, bytes_full - offset, 0, row_start, GlyphAtlas.width, rows_full - row_start, null);
    }
    if (bytes_full < bytes.len) {
        // Copy only the final row: temporary memory stays bounded at 64 KiB.
        const padded = try allocator.alloc(u8, GlyphAtlas.row_bytes);
        defer allocator.free(padded);

        const tail = bytes[bytes_full..];
        @memcpy(padded[0..tail.len], tail);
        @memset(padded[tail.len..], 0);
        try texture.write(padded.ptr, padded.len, 0, rows_full, GlyphAtlas.width, 1, null);
    }
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

test "glyph plane uploads bound padding and propagate partial upload failure" {
    const TestTexture = struct {
        calls: u32 = 0,
        fail_call: u32 = 2,
        pub fn write(self: *@This(), data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, stride: ?u32) !void {
            std.debug.assert(self.calls < 4);
            std.debug.assert(x == 0);
            try std.testing.expectEqual(GlyphAtlas.width, width);
            try std.testing.expectEqual(@as(u32, 1), height);
            try std.testing.expectEqual(@as(?u32, null), stride);
            try std.testing.expectEqual(GlyphAtlas.row_bytes, len);
            if (y == 1) {
                try std.testing.expectEqual(@as(u8, 7), data[0]);
                try std.testing.expectEqual(@as(u8, 0), data[GlyphAtlas.texel_bytes]);
                try std.testing.expectEqual(@as(u8, 0), data[len - 1]);
            } else {
                try std.testing.expectEqual(@as(u32, 0), y);
            }
            self.calls += 1;
            if (self.calls == self.fail_call) return error.UploadFailed;
        }
    };
    const bytes = try std.testing.allocator.alloc(u8, GlyphAtlas.row_bytes + GlyphAtlas.texel_bytes);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 7);
    var texture: TestTexture = .{};
    try std.testing.expectError(error.UploadFailed, uploadGlyphPlane(std.testing.allocator, &texture, bytes, 0));
    try std.testing.expectEqual(@as(u32, 2), texture.calls);
    texture.fail_call = 0;
    try uploadGlyphPlane(std.testing.allocator, &texture, bytes, 1);
    try std.testing.expectEqual(@as(u32, 3), texture.calls);
    try uploadGlyphPlane(std.testing.allocator, &texture, bytes, 2);
    try std.testing.expectEqual(@as(u32, 3), texture.calls);
}
