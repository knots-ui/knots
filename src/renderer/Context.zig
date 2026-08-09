const std = @import("std");
const gpu = @import("gpu");
const gpu_impl = @import("gpu_impl");

const pipelines = @import("pipelines.zig");
const Texture = @import("Texture.zig");

const Context = @This();

allocator: std.mem.Allocator,
device: gpu_impl.Device,
depth_buffer: bool,
pipeline: gpu_impl.Pipeline,
instance_pipeline: gpu_impl.Pipeline,
text_pipeline: gpu_impl.Pipeline,
linear_pipeline: ?gpu_impl.Pipeline,
linear_instance_pipeline: ?gpu_impl.Pipeline,
linear_text_pipeline: ?gpu_impl.Pipeline,
linear_sampler: ?gpu_impl.Sampler,
atlas: *Texture,
unit_index_buf: gpu_impl.Buffer,

pub fn create(allocator: std.mem.Allocator, window_handle: gpu.Context.WindowHandle, depth_buffer: bool) !*Context {
    const self = try allocator.create(Context);
    errdefer allocator.destroy(self);

    self.device = try .init(allocator, window_handle);
    errdefer self.device.deinit();
    self.depth_buffer = depth_buffer;

    const srgb_surface = self.device.surfaceIsSrgb();
    self.pipeline = try self.createPipeline(pipelines.primitivesDesc(.vertex, srgb_surface));
    errdefer self.pipeline.deinit();
    self.instance_pipeline = try self.createPipeline(
        pipelines.primitivesDesc(.instance, srgb_surface),
    );
    errdefer self.instance_pipeline.deinit();
    self.text_pipeline = try self.createPipeline(pipelines.slugDesc(srgb_surface));
    errdefer self.text_pipeline.deinit();

    const use_linear_target = gpu.Backend == .webgpu and !srgb_surface;
    self.linear_pipeline = if (use_linear_target)
        try self.createPipeline(pipelines.linearTargetPrimitivesDesc(.vertex))
    else
        null;
    errdefer if (self.linear_pipeline) |*p| p.deinit();
    self.linear_instance_pipeline = if (use_linear_target)
        try self.createPipeline(pipelines.linearTargetPrimitivesDesc(.instance))
    else
        null;
    errdefer if (self.linear_instance_pipeline) |*p| p.deinit();
    self.linear_text_pipeline = if (use_linear_target)
        try self.createPipeline(pipelines.linearTargetSlugDesc())
    else
        null;
    errdefer if (self.linear_text_pipeline) |*p| p.deinit();
    self.linear_sampler = if (use_linear_target)
        try self.device.createSampler(.{ .mag_filter = .nearest, .min_filter = .nearest, .label = "linear_sampler" })
    else
        null;
    errdefer if (self.linear_sampler) |*s| s.deinit();

    self.atlas = try Texture.create(allocator, &self.device, &self.pipeline, 1, 1, .r8, .nearest, "atlas_texture");
    errdefer self.atlas.destroyAfterWait();
    const pixel = [_]u8{0};
    try self.atlas.write(&pixel, 1, 1, null);

    self.unit_index_buf = try self.device.createBuffer(.{ .size = 6 * @sizeOf(u32), .usage = .{ .index = true, .copy_dst = true }, .label = "unit_indices" });
    errdefer self.unit_index_buf.deinit();
    self.unit_index_buf.load(u32, &.{ 0, 1, 2, 0, 2, 3 });

    self.allocator = allocator;
    return self;
}

pub fn createPipeline(self: *Context, desc: gpu.Pipeline.Desc) !gpu_impl.Pipeline {
    var resolved = desc;
    if (self.depth_buffer) {
        if (resolved.depth_stencil == null) {
            resolved.depth_stencil = .{
                .format = .depth24_plus,
                .depth_write_enabled = false,
                .depth_compare = .always,
            };
        }
    } else {
        if (resolved.depth_stencil != null) return error.DepthBufferDisabled;
    }
    return self.device.createPipeline(resolved);
}

pub fn destroy(self: *Context) void {
    self.device.waitIdle() catch {};
    self.unit_index_buf.deinit();
    self.atlas.destroyAfterWait();
    if (self.linear_sampler) |*s| s.deinit();
    if (self.linear_text_pipeline) |*p| p.deinit();
    if (self.linear_instance_pipeline) |*p| p.deinit();
    if (self.linear_pipeline) |*p| p.deinit();
    self.text_pipeline.deinit();
    self.instance_pipeline.deinit();
    self.pipeline.deinit();
    self.device.deinit();
    self.allocator.destroy(self);
}

pub fn createTexture(self: *Context, width: u32, height: u32, format: gpu.Texture.Format) !*Texture {
    return Texture.create(self.allocator, &self.device, &self.pipeline, width, height, format, .linear, "user_texture");
}
