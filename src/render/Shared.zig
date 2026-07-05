const std = @import("std");
const gpu = @import("gpu");
const gpu_impl = @import("gpu_impl");

const pipelines = @import("pipelines.zig");

const Shared = @This();

pub const TextureId = u64;

const TEX_INDEX_BITS: u6 = 32;
const TEX_INDEX_MASK: TextureId = (@as(TextureId, 1) << TEX_INDEX_BITS) - 1;
const MAX_TEXTURE_INDEX = std.math.maxInt(u32);
const PIXEL_TEXTURE_TTL_FRAMES: u32 = 2;
const PixelTextureKey = u64;

const TextureBinding = struct {
    texture: gpu_impl.Texture,
    sampler: gpu_impl.Sampler,
    width: u32,
    height: u32,
    format: gpu.Texture.Format,
};

const TextureSlot = struct {
    binding: ?TextureBinding,
    bg: ?gpu_impl.BindGroup = null,
    gen: u32,
    retired: bool = false,
};

const RetiredTexture = struct {
    binding: TextureBinding,
    bg: ?gpu_impl.BindGroup,
    retire_epoch: u64,
};

const PixelTextureCacheKey = struct {
    id: PixelTextureKey,
    data_ptr: usize,
    len: usize,
    width: u32,
    height: u32,
    format: gpu.Texture.Format,
    bytes_per_row: ?u32,
    version: u64,
};

const PixelTextureCacheEntry = struct {
    texture_id: TextureId,
    last_seen: u64,
};

const PixelTextureContext = struct {
    pub fn hash(_: PixelTextureContext, k: PixelTextureCacheKey) u64 {
        var h = std.hash.Wyhash.init(0);
        std.hash.autoHash(&h, k);
        return h.final();
    }

    pub fn eql(_: PixelTextureContext, a: PixelTextureCacheKey, b: PixelTextureCacheKey) bool {
        return a.id == b.id and
            a.data_ptr == b.data_ptr and
            a.len == b.len and
            a.width == b.width and
            a.height == b.height and
            a.format == b.format and
            a.bytes_per_row == b.bytes_per_row and
            a.version == b.version;
    }
};

const PixelTextureCache = std.HashMapUnmanaged(
    PixelTextureCacheKey,
    PixelTextureCacheEntry,
    PixelTextureContext,
    std.hash_map.default_max_load_percentage,
);

allocator: std.mem.Allocator,
pipeline: gpu_impl.Pipeline,
instance_pipeline: gpu_impl.Pipeline,
text_pipeline: gpu_impl.Pipeline,
linear_pipeline: ?gpu_impl.Pipeline = null,
linear_instance_pipeline: ?gpu_impl.Pipeline = null,
linear_text_pipeline: ?gpu_impl.Pipeline = null,
atlas_texture_bg: gpu_impl.BindGroup,
unit_index_buf: gpu_impl.Buffer,
atlas_texture: gpu_impl.Texture,
atlas_sampler: gpu_impl.Sampler,
linear_sampler: ?gpu_impl.Sampler = null,
texture_slots: std.ArrayList(TextureSlot),
free_slot_indices: std.ArrayList(u32),
retired_textures: std.ArrayList(RetiredTexture),
pixel_texture_cache: PixelTextureCache,
pixel_texture_scratch: std.ArrayList(PixelTextureCacheKey),
pixel_texture_epoch: u64,

pub fn init(allocator: std.mem.Allocator, device: *gpu_impl.Device) !Shared {
    const srgb_surface = device.surfaceIsSrgb();

    var pipeline = try device.createPipeline(pipelines.primitivesDesc(.vertex, srgb_surface));
    errdefer pipeline.deinit();

    var instance_pipeline = try device.createPipeline(pipelines.primitivesDesc(.instance, srgb_surface));
    errdefer instance_pipeline.deinit();

    var text_pipeline = try device.createPipeline(pipelines.slugDesc(srgb_surface));
    errdefer text_pipeline.deinit();

    const use_linear_target = gpu.Backend == .webgpu and !srgb_surface;
    var linear_pipeline: ?gpu_impl.Pipeline = if (use_linear_target)
        try device.createPipeline(pipelines.linearTargetPrimitivesDesc(.vertex))
    else
        null;
    errdefer if (linear_pipeline) |*p| p.deinit();

    var linear_instance_pipeline: ?gpu_impl.Pipeline = if (use_linear_target)
        try device.createPipeline(pipelines.linearTargetPrimitivesDesc(.instance))
    else
        null;
    errdefer if (linear_instance_pipeline) |*p| p.deinit();

    var linear_text_pipeline: ?gpu_impl.Pipeline = if (use_linear_target)
        try device.createPipeline(pipelines.linearTargetSlugDesc())
    else
        null;
    errdefer if (linear_text_pipeline) |*p| p.deinit();

    var atlas_texture = try device.createTexture(.{
        .width = 1,
        .height = 1,
        .format = .r8,
        .usage = .{ .texture_binding = true, .copy_dst = true },
    });
    errdefer atlas_texture.deinit();

    var atlas_sampler = try device.createSampler(.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
    });
    errdefer atlas_sampler.deinit();

    var linear_sampler: ?gpu_impl.Sampler = if (use_linear_target)
        try device.createSampler(.{ .mag_filter = .nearest, .min_filter = .nearest })
    else
        null;
    errdefer if (linear_sampler) |*s| s.deinit();

    const dummy_pixel = [_]u8{0};
    try atlas_texture.write(&dummy_pixel, 1, 0, 0, 1, 1, null);

    var atlas_texture_bg = try device.createBindGroup(.{
        .label = "atlas_texture_bg",
        .pipeline = &pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &atlas_texture } },
            .{ .binding = 1, .resource = .{ .sampler = &atlas_sampler } },
        },
    });
    errdefer atlas_texture_bg.deinit();

    var unit_index_buf = try device.createBuffer(6 * @sizeOf(u32), .{ .index = true, .copy_dst = true });
    errdefer unit_index_buf.deinit();
    const unit_indices = [_]u32{ 0, 1, 2, 0, 2, 3 };
    unit_index_buf.load(u32, &unit_indices);

    return .{
        .allocator = allocator,
        .pipeline = pipeline,
        .instance_pipeline = instance_pipeline,
        .text_pipeline = text_pipeline,
        .linear_pipeline = linear_pipeline,
        .linear_instance_pipeline = linear_instance_pipeline,
        .linear_text_pipeline = linear_text_pipeline,
        .atlas_texture_bg = atlas_texture_bg,
        .unit_index_buf = unit_index_buf,
        .atlas_texture = atlas_texture,
        .atlas_sampler = atlas_sampler,
        .linear_sampler = linear_sampler,
        .texture_slots = .empty,
        .free_slot_indices = .empty,
        .retired_textures = .empty,
        .pixel_texture_cache = .empty,
        .pixel_texture_scratch = .empty,
        .pixel_texture_epoch = 0,
    };
}

pub fn deinit(self: *Shared) void {
    self.atlas_texture_bg.deinit();
    for (self.texture_slots.items) |*slot| _ = destroyTextureSlotNow(slot);
    self.texture_slots.deinit(self.allocator);
    self.free_slot_indices.deinit(self.allocator);
    for (self.retired_textures.items) |*entry| destroyTextureBinding(&entry.binding, &entry.bg);
    self.retired_textures.deinit(self.allocator);
    self.pixel_texture_cache.deinit(self.allocator);
    self.pixel_texture_scratch.deinit(self.allocator);
    self.pipeline.deinit();
    self.instance_pipeline.deinit();
    self.text_pipeline.deinit();
    if (self.linear_pipeline) |*p| p.deinit();
    if (self.linear_instance_pipeline) |*p| p.deinit();
    if (self.linear_text_pipeline) |*p| p.deinit();
    if (self.linear_sampler) |*s| s.deinit();
    self.unit_index_buf.deinit();
    self.atlas_texture.deinit();
    self.atlas_sampler.deinit();
}

pub fn createTexture(self: *Shared, device: *gpu_impl.Device, width: u32, height: u32, format: gpu.Texture.Format) !TextureId {
    var sampler = try device.createSampler(.{ .mag_filter = .linear, .min_filter = .linear });
    errdefer sampler.deinit();
    var texture = try device.createTexture(.{
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

    while (self.free_slot_indices.pop()) |idx| {
        const slot = &self.texture_slots.items[idx];
        if (slot.retired) continue;
        slot.binding = binding;
        return packTextureId(idx, slot.gen);
    }

    if (self.texture_slots.items.len > MAX_TEXTURE_INDEX) return error.MaxTexturesReached;
    const idx: u32 = @intCast(self.texture_slots.items.len);
    try self.free_slot_indices.ensureTotalCapacity(self.allocator, self.texture_slots.items.len + 1);
    try self.retired_textures.ensureUnusedCapacity(self.allocator, 1);
    try self.texture_slots.append(self.allocator, .{ .binding = binding, .gen = 0 });
    return packTextureId(idx, 0);
}

pub fn writeTexture(self: *Shared, id: TextureId, data: [*]const u8, len: usize, width: u32, height: u32, bytes_per_row: ?u32) !void {
    const binding = (try self.lookupTexture(id)) orelse return error.InvalidTextureId;
    if (width > binding.width or height > binding.height) return error.InvalidTextureWrite;
    const required = try requiredTextureBytes(width, height, bytesPerGpuPixel(binding.format), bytes_per_row);
    if (len < required) return error.InvalidTextureWrite;
    try binding.texture.write(data, len, 0, 0, width, height, bytes_per_row);
}

pub fn destroyTexture(self: *Shared, id: TextureId) !void {
    const idx: u32 = @intCast(id & TEX_INDEX_MASK);
    if (idx >= self.texture_slots.items.len) return error.InvalidTextureId;
    const slot = &self.texture_slots.items[idx];
    if ((id >> TEX_INDEX_BITS) != slot.gen) return error.InvalidTextureId;
    if (slot.binding == null) return error.InvalidTextureId;
    if (try self.retireTextureSlot(slot, self.pixel_texture_epoch)) self.free_slot_indices.appendAssumeCapacity(idx);
}

pub fn destroyTextureNoAlloc(self: *Shared, id: TextureId) void {
    const idx: u32 = @intCast(id & TEX_INDEX_MASK);
    if (idx >= self.texture_slots.items.len) return;
    const slot = &self.texture_slots.items[idx];
    if ((id >> TEX_INDEX_BITS) != slot.gen or slot.binding == null) return;
    const can_reuse = if (self.retired_textures.items.len < self.retired_textures.capacity)
        retireTextureSlotAssumeCapacity(self, slot, self.pixel_texture_epoch)
    else
        destroyTextureSlotNow(slot);
    if (can_reuse) self.free_slot_indices.appendAssumeCapacity(idx);
}

pub fn bindGroupForTexture(self: *Shared, device: *gpu_impl.Device, id: ?TextureId) !*gpu_impl.BindGroup {
    const tex_id = id orelse return &self.atlas_texture_bg;
    const idx: u32 = @intCast(tex_id & TEX_INDEX_MASK);
    if (idx >= self.texture_slots.items.len) return &self.atlas_texture_bg;

    const slot = &self.texture_slots.items[idx];
    if ((tex_id >> TEX_INDEX_BITS) != slot.gen or slot.binding == null) return &self.atlas_texture_bg;

    if (slot.bg) |*bg| return bg;

    const binding = &slot.binding.?;
    slot.bg = try device.createBindGroup(.{
        .label = "user_texture_bg",
        .pipeline = &self.pipeline,
        .layout_index = 1,
        .entries = &.{
            .{ .binding = 0, .resource = .{ .texture_view = &binding.texture } },
            .{ .binding = 1, .resource = .{ .sampler = &binding.sampler } },
        },
    });
    if (slot.bg) |*bg| return bg;
    unreachable;
}

pub fn textureFromPixels(
    self: *Shared,
    device: *gpu_impl.Device,
    id: PixelTextureKey,
    data: []const u8,
    width: u32,
    height: u32,
    format: gpu.Texture.Format,
    bytes_per_row: ?u32,
    version: u64,
    force_upload: bool,
) !TextureId {
    const required = try requiredTextureBytes(width, height, bytesPerGpuPixel(format), bytes_per_row);
    if (data.len < required) return error.InvalidTextureWrite;

    const key: PixelTextureCacheKey = .{
        .id = id,
        .data_ptr = @intFromPtr(data.ptr),
        .len = data.len,
        .width = width,
        .height = height,
        .format = format,
        .bytes_per_row = bytes_per_row,
        .version = version,
    };

    const gop = try self.pixel_texture_cache.getOrPutContext(self.allocator, key, .{});
    errdefer _ = if (!gop.found_existing) self.pixel_texture_cache.remove(key);

    if (!gop.found_existing) {
        const tex = try self.createTexture(device, width, height, format);
        errdefer self.destroyTexture(tex) catch {};
        try self.writeTexture(tex, data.ptr, data.len, width, height, bytes_per_row);
        gop.value_ptr.* = .{
            .texture_id = tex,
            .last_seen = self.pixel_texture_epoch,
        };
        return tex;
    }

    gop.value_ptr.last_seen = self.pixel_texture_epoch;
    if (force_upload) {
        try self.writeTexture(gop.value_ptr.texture_id, data.ptr, data.len, width, height, bytes_per_row);
    }
    return gop.value_ptr.texture_id;
}

pub fn sweepPixelTextureCache(self: *Shared, retire_grace_epochs: u64) !void {
    self.pixel_texture_scratch.clearRetainingCapacity();

    var it = self.pixel_texture_cache.iterator();
    while (it.next()) |kv| {
        if (self.pixel_texture_epoch -% kv.value_ptr.last_seen >= PIXEL_TEXTURE_TTL_FRAMES) {
            try self.pixel_texture_scratch.append(self.allocator, kv.key_ptr.*);
        }
    }

    for (self.pixel_texture_scratch.items) |key| {
        const entry = self.pixel_texture_cache.get(key) orelse continue;
        try self.destroyTexture(entry.texture_id);
        _ = self.pixel_texture_cache.remove(key);
    }

    self.sweepRetiredTextures(retire_grace_epochs);
    self.pixel_texture_epoch +%= 1;
}

pub fn requiredTextureBytes(width: u32, height: u32, bpp: usize, bytes_per_row: ?u32) !usize {
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

pub fn bytesPerGpuPixel(format: gpu.Texture.Format) usize {
    return switch (format) {
        .r8 => 1,
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .rgba32f, .rgba32u => 16,
    };
}

fn lookupTexture(self: *Shared, id: TextureId) !?*TextureBinding {
    const idx: u32 = @intCast(id & TEX_INDEX_MASK);
    if (idx >= self.texture_slots.items.len) return error.InvalidTextureId;
    const slot = &self.texture_slots.items[idx];
    if ((id >> TEX_INDEX_BITS) != slot.gen) return error.InvalidTextureId;
    if (slot.binding) |*binding| return binding;
    return null;
}

fn packTextureId(idx: u32, gen: u32) TextureId {
    return (@as(TextureId, gen) << TEX_INDEX_BITS) | @as(TextureId, idx);
}

fn retireTextureSlot(self: *Shared, slot: *TextureSlot, retire_epoch: u64) !bool {
    const binding = slot.binding orelse return !slot.retired;
    try self.retired_textures.append(self.allocator, .{
        .binding = binding,
        .bg = slot.bg,
        .retire_epoch = retire_epoch,
    });
    slot.binding = null;
    slot.bg = null;
    return advanceTextureSlotGeneration(slot);
}

fn retireTextureSlotAssumeCapacity(self: *Shared, slot: *TextureSlot, retire_epoch: u64) bool {
    const binding = slot.binding orelse return !slot.retired;
    self.retired_textures.appendAssumeCapacity(.{
        .binding = binding,
        .bg = slot.bg,
        .retire_epoch = retire_epoch,
    });
    slot.binding = null;
    slot.bg = null;
    return advanceTextureSlotGeneration(slot);
}

fn destroyTextureSlotNow(slot: *TextureSlot) bool {
    if (slot.binding) |*binding| {
        destroyTextureBinding(binding, &slot.bg);
        slot.binding = null;
    } else if (slot.bg) |*bg| {
        bg.deinit();
        slot.bg = null;
    }
    return advanceTextureSlotGeneration(slot);
}

fn advanceTextureSlotGeneration(slot: *TextureSlot) bool {
    if (slot.gen == std.math.maxInt(u32)) {
        slot.retired = true;
        return false;
    }
    slot.gen +%= 1;
    return !slot.retired;
}

fn sweepRetiredTextures(self: *Shared, grace_epochs: u64) void {
    var i: usize = 0;
    while (i < self.retired_textures.items.len) {
        const entry = &self.retired_textures.items[i];
        if (self.pixel_texture_epoch -% entry.retire_epoch < grace_epochs) {
            i += 1;
            continue;
        }
        destroyTextureBinding(&entry.binding, &entry.bg);
        _ = self.retired_textures.swapRemove(i);
    }
}

fn destroyTextureBinding(binding: *TextureBinding, bg: *?gpu_impl.BindGroup) void {
    if (bg.*) |*bind_group| bind_group.deinit();
    bg.* = null;
    binding.texture.deinit();
    binding.sampler.deinit();
}
