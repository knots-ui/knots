const std = @import("std");
const gpu = @import("gpu");
const gpu_impl = @import("gpu_impl");
const pipelines = @import("pipelines.zig");
const Clip = @import("render").Clip;
const Context = @import("Context.zig");

const INIT_VERTEX_BYTES = 256 * 1024;
const INIT_INSTANCE_BYTES = 64 * 1024;
const INIT_INDEX_COUNT = 64 * 1024;
const INIT_TEXT_INSTANCE_BYTES = 128 * 1024;
const INIT_CLIP_NODE_COUNT = 64;
const CUSTOM_UPLOAD_CHUNK_BYTES = 4096;
const CUSTOM_UPLOAD_ALIGNMENT = 256;

const UploadChunk = struct {
    buffer: gpu_impl.Buffer,
    usage: gpu.Buffer.Usage,
    used: usize = 0,
};

pub const UploadView = struct {
    chunk_index: u32,
    epoch: u64,
    offset: usize,
    size: usize,
};

pub const BindGroupRef = struct {
    slot_index: u32,
    epoch: u64,
};

context: *Context,
upload_chunks: std.ArrayList(UploadChunk),
bind_group_slots: std.ArrayList(?gpu_impl.BindGroup),
bind_group_count: usize,
custom_epoch: u64,
frame_context: ?gpu_impl.Frame.Context = null,

vertex_uniform_buf: gpu_impl.Buffer,
instance_uniform_buf: gpu_impl.Buffer,
text_uniform_buf: gpu_impl.Buffer,
vertex_uniform_bg: gpu_impl.BindGroup,
instance_uniform_bg: gpu_impl.BindGroup,
text_uniform_bg: gpu_impl.BindGroup,
vertex_clip_bg: gpu_impl.BindGroup,
instance_clip_bg: gpu_impl.BindGroup,
text_clip_bg: gpu_impl.BindGroup,

vertex_buf: gpu_impl.Buffer,
index_buf: gpu_impl.Buffer,
instance_buf: gpu_impl.Buffer,
composite_instance_buf: gpu_impl.Buffer,
text_instance_buf: gpu_impl.Buffer,
clip_node_buf: gpu_impl.Buffer,

const FrameUploads = @This();

pub fn init(ctx: *Context) !FrameUploads {
    var vertex_uniform_buf = try ctx.device.createBuffer(.{ .size = @sizeOf(pipelines.ViewportUniform), .usage = .{ .uniform = true, .copy_dst = true }, .label = "vertex_viewport_uniform" });
    errdefer vertex_uniform_buf.deinit();
    var instance_uniform_buf = try ctx.device.createBuffer(.{ .size = @sizeOf(pipelines.ViewportUniform), .usage = .{ .uniform = true, .copy_dst = true }, .label = "instance_viewport_uniform" });
    errdefer instance_uniform_buf.deinit();
    var text_uniform_buf = try ctx.device.createBuffer(.{ .size = @sizeOf(pipelines.SlugUniforms), .usage = .{ .uniform = true, .copy_dst = true }, .label = "text_uniforms" });
    errdefer text_uniform_buf.deinit();
    var clip_node_buf = try ctx.device.createBuffer(.{ .size = INIT_CLIP_NODE_COUNT * @sizeOf(Clip.Node), .usage = .{ .storage = true, .copy_dst = true }, .label = "clip_nodes" });
    errdefer clip_node_buf.deinit();
    clip_node_buf.load(Clip.Node, &.{Clip.Node.empty});

    var vertex_uniform_bg = try ctx.device.createBindGroup(.{
        .label = "vertex_uniform_bg",
        .pipeline = &ctx.pipeline,
        .layout_index = 0,
        .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = &vertex_uniform_buf, .size = @sizeOf(pipelines.ViewportUniform) } } }},
    });
    errdefer vertex_uniform_bg.deinit();

    var instance_uniform_bg = try ctx.device.createBindGroup(.{
        .label = "instance_uniform_bg",
        .pipeline = &ctx.instance_pipeline,
        .layout_index = 0,
        .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = &instance_uniform_buf, .size = @sizeOf(pipelines.ViewportUniform) } } }},
    });
    errdefer instance_uniform_bg.deinit();

    var text_uniform_bg = try ctx.device.createBindGroup(.{
        .label = "text_uniform_bg",
        .pipeline = &ctx.text_pipeline,
        .layout_index = 0,
        .entries = &.{.{ .binding = 0, .resource = .{ .buffer = .{ .buffer = &text_uniform_buf, .size = @sizeOf(pipelines.SlugUniforms) } } }},
    });
    errdefer text_uniform_bg.deinit();

    var vertex_clip_bg = try createClipBindGroup(&ctx.device, &ctx.pipeline, &clip_node_buf, "vertex_clip_bg");
    errdefer vertex_clip_bg.deinit();
    var instance_clip_bg = try createClipBindGroup(&ctx.device, &ctx.instance_pipeline, &clip_node_buf, "instance_clip_bg");
    errdefer instance_clip_bg.deinit();
    var text_clip_bg = try createClipBindGroup(&ctx.device, &ctx.text_pipeline, &clip_node_buf, "text_clip_bg");
    errdefer text_clip_bg.deinit();

    var vertex_buf = try ctx.device.createBuffer(.{ .size = INIT_VERTEX_BYTES, .usage = .{ .vertex = true, .copy_dst = true }, .label = "ui_vertices" });
    errdefer vertex_buf.deinit();
    var instance_buf = try ctx.device.createBuffer(.{ .size = INIT_INSTANCE_BYTES, .usage = .{ .vertex = true, .copy_dst = true }, .label = "ui_instances" });
    errdefer instance_buf.deinit();
    var composite_instance_buf = try ctx.device.createBuffer(.{ .size = @sizeOf(gpu.Instance), .usage = .{ .vertex = true, .copy_dst = true }, .label = "composite_instance" });
    errdefer composite_instance_buf.deinit();
    var text_instance_buf = try ctx.device.createBuffer(.{ .size = INIT_TEXT_INSTANCE_BYTES, .usage = .{ .vertex = true, .copy_dst = true }, .label = "text_instances" });
    errdefer text_instance_buf.deinit();
    var index_buf = try ctx.device.createBuffer(.{ .size = INIT_INDEX_COUNT * @sizeOf(u32), .usage = .{ .index = true, .copy_dst = true }, .label = "ui_indices" });
    errdefer index_buf.deinit();

    return .{
        .context = ctx,
        .upload_chunks = .empty,
        .bind_group_slots = .empty,
        .bind_group_count = 0,
        .custom_epoch = 0,
        .vertex_uniform_buf = vertex_uniform_buf,
        .instance_uniform_buf = instance_uniform_buf,
        .text_uniform_buf = text_uniform_buf,
        .vertex_uniform_bg = vertex_uniform_bg,
        .instance_uniform_bg = instance_uniform_bg,
        .text_uniform_bg = text_uniform_bg,
        .vertex_clip_bg = vertex_clip_bg,
        .instance_clip_bg = instance_clip_bg,
        .text_clip_bg = text_clip_bg,
        .vertex_buf = vertex_buf,
        .index_buf = index_buf,
        .instance_buf = instance_buf,
        .composite_instance_buf = composite_instance_buf,
        .text_instance_buf = text_instance_buf,
        .clip_node_buf = clip_node_buf,
    };
}

pub fn deinit(self: *FrameUploads) void {
    for (self.bind_group_slots.items[0..self.bind_group_count]) |*slot| {
        if (slot.*) |*value| value.deinit();
    }
    self.bind_group_slots.deinit(self.context.allocator);
    for (self.upload_chunks.items) |*chunk| chunk.buffer.deinit();
    self.upload_chunks.deinit(self.context.allocator);
    self.vertex_clip_bg.deinit();
    self.instance_clip_bg.deinit();
    self.text_clip_bg.deinit();
    self.vertex_uniform_bg.deinit();
    self.instance_uniform_bg.deinit();
    self.text_uniform_bg.deinit();
    self.vertex_uniform_buf.deinit();
    self.instance_uniform_buf.deinit();
    self.text_uniform_buf.deinit();
    self.vertex_buf.deinit();
    self.index_buf.deinit();
    self.instance_buf.deinit();
    self.composite_instance_buf.deinit();
    self.text_instance_buf.deinit();
    self.clip_node_buf.deinit();
}

pub fn resetCustom(self: *FrameUploads, frame_context: gpu_impl.Frame.Context) void {
    for (self.bind_group_slots.items[0..self.bind_group_count]) |*slot| {
        if (slot.*) |*value| value.deinit();
        slot.* = null;
    }
    self.bind_group_count = 0;
    for (self.upload_chunks.items) |*chunk| chunk.used = 0;
    self.custom_epoch +%= 1;
    self.frame_context = frame_context;
}

pub fn upload(self: *FrameUploads, comptime T: type, values: []const T, requested_usage: gpu.Buffer.Usage) !UploadView {
    if (@sizeOf(T) == 0 or values.len == 0) return error.EmptyBufferUpload;
    const size = std.math.mul(usize, @sizeOf(T), values.len) catch return error.BufferUploadTooLarge;
    if (size % 4 != 0) return error.UnalignedBufferUpload;

    var usage = requested_usage;
    usage.copy_dst = true;
    for (self.upload_chunks.items, 0..) |*chunk, chunk_index| {
        if (!std.meta.eql(chunk.usage, usage)) continue;
        const offset = (std.math.add(usize, chunk.used, CUSTOM_UPLOAD_ALIGNMENT - 1) catch continue) &
            ~@as(usize, CUSTOM_UPLOAD_ALIGNMENT - 1);
        if (offset <= chunk.buffer.getSize() and size <= chunk.buffer.getSize() - offset) {
            chunk.buffer.loadOffset(T, values, offset);
            chunk.used = offset + size;
            return .{ .chunk_index = @intCast(chunk_index), .epoch = self.custom_epoch, .offset = offset, .size = size };
        }
    }

    const required = (std.math.add(usize, size, CUSTOM_UPLOAD_ALIGNMENT - 1) catch return error.BufferUploadTooLarge) &
        ~@as(usize, CUSTOM_UPLOAD_ALIGNMENT - 1);
    const capacity = std.math.ceilPowerOfTwo(usize, @max(CUSTOM_UPLOAD_CHUNK_BYTES, required)) catch return error.BufferUploadTooLarge;
    var buffer = try self.context.device.createBuffer(.{
        .size = capacity,
        .usage = usage,
        .label = "custom_frame_upload",
    });
    errdefer buffer.deinit();
    try self.upload_chunks.append(self.context.allocator, .{ .buffer = buffer, .usage = usage });

    const chunk_index: u32 = @intCast(self.upload_chunks.items.len - 1);
    const chunk = &self.upload_chunks.items[chunk_index];
    chunk.buffer.loadOffset(T, values, 0);
    chunk.used = size;
    return .{ .chunk_index = chunk_index, .epoch = self.custom_epoch, .offset = 0, .size = size };
}

pub fn createBindGroup(self: *FrameUploads, desc: gpu_impl.BindGroup.Desc) !BindGroupRef {
    if (self.bind_group_count == self.bind_group_slots.items.len)
        try self.bind_group_slots.append(self.context.allocator, null);
    const slot = &self.bind_group_slots.items[self.bind_group_count];
    std.debug.assert(slot.* == null);
    slot.* = try self.frame_context.?.createBindGroup(desc);
    const slot_index: u32 = @intCast(self.bind_group_count);
    self.bind_group_count += 1;
    return .{ .slot_index = slot_index, .epoch = self.custom_epoch };
}

pub fn uploadBuffer(self: *const FrameUploads, chunk_index: u32, epoch: u64) ?*const gpu_impl.Buffer {
    if (epoch != self.custom_epoch or chunk_index >= self.upload_chunks.items.len) return null;
    return &self.upload_chunks.items[chunk_index].buffer;
}

pub fn uploadBindGroup(self: *const FrameUploads, slot_index: u32, epoch: u64) ?*const gpu_impl.BindGroup {
    if (epoch != self.custom_epoch or slot_index >= self.bind_group_count) return null;
    return if (self.bind_group_slots.items[slot_index]) |*value| value else unreachable;
}

pub fn ensureClipNodeCapacity(self: *FrameUploads, context: *Context, required: usize) !void {
    if (required <= self.clip_node_buf.getSize()) return;

    const current_size = self.clip_node_buf.getSize();
    const new_size = @max(required, current_size + current_size / 2);

    const device = &context.device;
    var clip_node_buf = try device.createBuffer(.{ .size = new_size, .usage = .{ .storage = true, .copy_dst = true }, .label = "clip_nodes" });
    errdefer clip_node_buf.deinit();
    clip_node_buf.load(Clip.Node, &.{Clip.Node.empty});

    var vertex_clip_bg = try createClipBindGroup(device, &context.pipeline, &clip_node_buf, "vertex_clip_bg");
    errdefer vertex_clip_bg.deinit();
    var instance_clip_bg = try createClipBindGroup(device, &context.instance_pipeline, &clip_node_buf, "instance_clip_bg");
    errdefer instance_clip_bg.deinit();
    var text_clip_bg = try createClipBindGroup(device, &context.text_pipeline, &clip_node_buf, "text_clip_bg");
    errdefer text_clip_bg.deinit();

    self.vertex_clip_bg.deinit();
    self.instance_clip_bg.deinit();
    self.text_clip_bg.deinit();
    self.clip_node_buf.deinit();
    self.vertex_clip_bg = vertex_clip_bg;
    self.instance_clip_bg = instance_clip_bg;
    self.text_clip_bg = text_clip_bg;
    self.clip_node_buf = clip_node_buf;
}

fn createClipBindGroup(device: *gpu_impl.Device, pipeline: *const gpu_impl.Pipeline, buf: *const gpu_impl.Buffer, label: []const u8) !gpu_impl.BindGroup {
    return device.createBindGroup(.{
        .label = label,
        .pipeline = pipeline,
        .layout_index = 2,
        .entries = &.{.{ .binding = 0, .resource = .{ .read_only_storage_buffer = .{ .buffer = buf, .size = @intCast(buf.getSize()) } } }},
    });
}
