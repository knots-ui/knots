const std = @import("std");
const wgpu = @import("wgpu");
const gpu = @import("gpu");
const Context = @import("Context.zig");

const Pipeline = @This();

allocator: std.mem.Allocator,
render_pipeline: wgpu.RenderPipeline,
bind_group_layouts: []wgpu.BindGroupLayout,
device: wgpu.Device,

pub fn create(allocator: std.mem.Allocator, ctx: *Context, desc: gpu.Pipeline.Desc) !gpu.Pipeline {
    const wgsl = switch (desc.shader) {
        .wgsl => |s| s,
        .spirv => return error.UnsupportedShaderSource,
    };

    const shader_module = try wgpu.ShaderModule.init(ctx.device.device, .{ .wgsl = wgsl });
    defer shader_module.deinit();

    const bgls = try allocator.alloc(wgpu.BindGroupLayout, desc.bind_group_layouts.len);
    errdefer allocator.free(bgls);
    var bgls_created: usize = 0;
    errdefer for (bgls[0..bgls_created]) |bgl| bgl.deinit();

    var entry_buf: [16]wgpu.BindGroupLayout.Entry = undefined;

    for (desc.bind_group_layouts, 0..) |bgl_desc, bgl_i| {
        if (bgl_desc.entries.len > entry_buf.len) return error.TooManyBindGroupEntries;
        for (bgl_desc.entries, 0..) |e, i| {
            entry_buf[i] = toWgpuBglEntry(e);
        }
        bgls[bgl_i] = try ctx.device.createBindGroupLayout(.{
            .label = bgl_desc.label,
            .entries = entry_buf[0..bgl_desc.entries.len],
        });
        bgls_created += 1;
    }

    const pipeline_layout = try ctx.device.createPipelineLayout(desc.label, bgls);
    defer pipeline_layout.deinit();

    var attr_buf: [4][16]wgpu.RenderPipeline.VertexAttribute = undefined;
    var vbl_buf: [4]wgpu.RenderPipeline.VertexBufferLayout = undefined;
    if (desc.vertex_buffers.len > vbl_buf.len) return error.TooManyVertexBuffers;
    for (desc.vertex_buffers, 0..) |vb, i| {
        if (vb.attributes.len > attr_buf[i].len) return error.TooManyVertexAttributes;
        for (vb.attributes, 0..) |a, j| {
            attr_buf[i][j] = .{
                .shader_location = a.location,
                .offset = a.offset,
                .format = toWgpuVertexFormat(a.format),
            };
        }
        vbl_buf[i] = .{
            .array_stride = vb.stride,
            .step_mode = switch (vb.step_mode) {
                .vertex => .vertex,
                .instance => .instance,
            },
            .attributes = attr_buf[i][0..vb.attributes.len],
        };
    }

    const target_format = if (desc.color_target.format) |f| toWgpuFormat(f) else ctx.surface_format;
    const blend = if (desc.color_target.blend) |b| toWgpuBlend(b) else null;

    const pipeline = try ctx.device.createRenderPipeline(.{
        .label = desc.label,
        .layout = pipeline_layout,
        .vertex = .{
            .module = shader_module,
            .entry_point = desc.vs_entry,
            .buffers = vbl_buf[0..desc.vertex_buffers.len],
        },
        .fragment = .{
            .module = shader_module,
            .entry_point = desc.fs_entry,
            .targets = &.{.{ .format = target_format, .blend = blend }},
        },
    });

    const self = try allocator.create(Pipeline);
    self.* = .{
        .allocator = allocator,
        .render_pipeline = pipeline,
        .bind_group_layouts = bgls,
        .device = ctx.device,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = gpu.Pipeline.VTable{
    .deinit = &deinit,
};

fn deinit(ptr: *anyopaque) void {
    const self: *Pipeline = @ptrCast(@alignCast(ptr));
    self.render_pipeline.deinit();
    for (self.bind_group_layouts) |bgl| bgl.deinit();
    self.allocator.free(self.bind_group_layouts);
    self.allocator.destroy(self);
}

fn toWgpuBglEntry(e: gpu.Pipeline.BindGroupLayoutEntry) wgpu.BindGroupLayout.Entry {
    var out: wgpu.BindGroupLayout.Entry = .{
        .binding = e.binding,
        .visibility = .{ .vertex = e.visibility.vertex, .fragment = e.visibility.fragment },
    };
    switch (e.type) {
        .uniform_buffer => out.buffer = .{ .binding_type = .uniform },
        .read_only_storage_buffer => out.buffer = .{ .binding_type = .read_only_storage },
        .sampled_texture => |st| out.texture = .{
            .sample_type = switch (st) {
                .float => .float,
                .unfilterable_float => .unfilterable_float,
                .uint => .uint,
            },
            .view_dimension = .@"2d",
        },
        .sampler => |sb| out.sampler = .{
            .binding_type = switch (sb) {
                .filtering => .filtering,
                .non_filtering => .non_filtering,
            },
        },
    }
    return out;
}

fn toWgpuVertexFormat(f: gpu.Pipeline.VertexFormat) wgpu.RenderPipeline.VertexFormat {
    return switch (f) {
        .f32 => .float32,
        .f32x2 => .float32x2,
        .f32x3 => .float32x3,
        .f32x4 => .float32x4,
    };
}

fn toWgpuFormat(f: gpu.Texture.Format) wgpu.Texture.Format {
    return switch (f) {
        .rgba8 => .rgba8_unorm,
        .rgba8_srgb => .rgba8_unorm_srgb,
        .bgra8 => .bgra8_unorm,
        .bgra8_srgb => .bgra8_unorm_srgb,
        .r8 => .r8_unorm,
        .rgba32f => .rgba32_float,
        .rgba32u => .rgba32_uint,
    };
}

fn toWgpuBlendFactor(f: gpu.Pipeline.BlendFactor) wgpu.RenderPipeline.BlendFactor {
    return switch (f) {
        .zero => .zero,
        .one => .one,
        .src_alpha => .src_alpha,
        .one_minus_src_alpha => .one_minus_src_alpha,
    };
}

fn toWgpuBlendOp(o: gpu.Pipeline.BlendOp) wgpu.RenderPipeline.BlendOperation {
    return switch (o) {
        .add => .add,
    };
}

fn toWgpuBlend(b: gpu.Pipeline.BlendState) wgpu.RenderPipeline.BlendState {
    return .{
        .color = .{
            .operation = toWgpuBlendOp(b.color.op),
            .src_factor = toWgpuBlendFactor(b.color.src_factor),
            .dst_factor = toWgpuBlendFactor(b.color.dst_factor),
        },
        .alpha = .{
            .operation = toWgpuBlendOp(b.alpha.op),
            .src_factor = toWgpuBlendFactor(b.alpha.src_factor),
            .dst_factor = toWgpuBlendFactor(b.alpha.dst_factor),
        },
    };
}

pub fn bindGroupLayout(self: *const Pipeline, index: u32) wgpu.BindGroupLayout {
    return self.bind_group_layouts[index];
}
