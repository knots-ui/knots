const std = @import("std");
const wgpu = @import("wgpu");
const gpu = @import("gpu");
const Context = @import("Context.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const Pipeline = @This();

const ui_primitives_src = @embedFile("shaders/ui_primitives.wgsl");
const slug_src = @embedFile("shaders/slug.wgsl");

const SlugUniforms = extern struct {
    mvp_row0: [4]f32,
    mvp_row1: [4]f32,
    mvp_row2: [4]f32,
    mvp_row3: [4]f32,
    viewport: [4]f32,
};

allocator: std.mem.Allocator,
kind: gpu.Pipeline.Kind,
render_pipeline: wgpu.RenderPipeline,
bind_group_layout: wgpu.BindGroupLayout,
bind_group: ?wgpu.BindGroup,
uniform_buffer: wgpu.Buffer,
uniform_size: usize,
queue: wgpu.Queue,
device: wgpu.Device,

pub fn create(allocator: std.mem.Allocator, ctx: *Context, desc: gpu.Pipeline.Desc) !gpu.Pipeline {
    return switch (desc.kind) {
        .vertex, .instance => createPrimitives(allocator, ctx, desc),
        .text => createSlug(allocator, ctx),
    };
}

fn createPrimitives(allocator: std.mem.Allocator, ctx: *Context, desc: gpu.Pipeline.Desc) !gpu.Pipeline {
    const self = try allocator.create(Pipeline);
    errdefer allocator.destroy(self);

    const shader_module = try wgpu.ShaderModule.init(ctx.device.device, .{ .wgsl = ui_primitives_src });
    defer shader_module.deinit();

    const uniform_size = 2 * @sizeOf(f32);
    const uniform_buffer = try ctx.device.createBuffer(.{
        .usage = .{ .uniform = true, .copy_dst = true },
        .size = uniform_size,
        .label = "",
    });

    const bgl_entries = &[_]wgpu.BindGroupLayout.Entry{
        .{ .binding = 0, .visibility = .{ .vertex = true }, .buffer = .{ .binding_type = .uniform } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .float, .view_dimension = .@"2d" } },
        .{ .binding = 2, .visibility = .{ .fragment = true }, .sampler = .{ .binding_type = .filtering } },
    };

    const bgl = try ctx.device.createBindGroupLayout(.{ .label = "unified_bgl", .entries = bgl_entries });
    const pipeline_layout = try ctx.device.createPipelineLayout("unified_pipeline_layout", &.{bgl});
    defer pipeline_layout.deinit();

    const vertex_attributes = toAttributes(gpu.Vertex);
    const instance_attributes = toAttributes(gpu.Instance);

    const vertex_buffers: []const wgpu.RenderPipeline.VertexBufferLayout = switch (desc.kind) {
        .vertex => &.{.{ .array_stride = @sizeOf(gpu.Vertex), .step_mode = .vertex, .attributes = &vertex_attributes }},
        .instance => &.{.{ .array_stride = @sizeOf(gpu.Instance), .step_mode = .instance, .attributes = &instance_attributes }},
        .text => unreachable,
    };

    const vs_entry: []const u8 = switch (desc.kind) {
        .vertex => "vs_main",
        .instance => "vs_instance_main",
        .text => unreachable,
    };

    const pipeline = try ctx.device.createRenderPipeline(.{
        .label = "unified_pipeline",
        .layout = pipeline_layout,
        .vertex = .{ .module = shader_module, .entry_point = vs_entry, .buffers = vertex_buffers },
        .fragment = .{
            .module = shader_module,
            .entry_point = if (ctx.surface_is_srgb) "fs_main" else "fs_main_srgb_encode",
            .targets = &.{.{
                .format = ctx.surface_format,
                .blend = .{
                    .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha, .operation = .add },
                    .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha, .operation = .add },
                },
            }},
        },
    });

    self.* = .{
        .allocator = allocator,
        .kind = desc.kind,
        .render_pipeline = pipeline,
        .bind_group_layout = bgl,
        .bind_group = null,
        .uniform_buffer = uniform_buffer,
        .uniform_size = uniform_size,
        .queue = ctx.queue,
        .device = ctx.device,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

fn createSlug(allocator: std.mem.Allocator, ctx: *Context) !gpu.Pipeline {
    const self = try allocator.create(Pipeline);
    errdefer allocator.destroy(self);

    const shader_module = try wgpu.ShaderModule.init(ctx.device.device, .{ .wgsl = slug_src });
    defer shader_module.deinit();

    const uniform_size = @sizeOf(SlugUniforms);
    const uniform_buffer = try ctx.device.createBuffer(.{
        .usage = .{ .uniform = true, .copy_dst = true },
        .size = uniform_size,
        .label = "slug_uniforms",
    });

    const bgl_entries = &[_]wgpu.BindGroupLayout.Entry{
        .{ .binding = 0, .visibility = .{ .vertex = true, .fragment = true }, .buffer = .{ .binding_type = .uniform } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .unfilterable_float, .view_dimension = .@"2d" } },
        .{ .binding = 2, .visibility = .{ .fragment = true }, .texture = .{ .sample_type = .uint, .view_dimension = .@"2d" } },
    };

    const bgl = try ctx.device.createBindGroupLayout(.{ .label = "slug_bgl", .entries = bgl_entries });
    const pipeline_layout = try ctx.device.createPipelineLayout("slug_pipeline_layout", &.{bgl});
    defer pipeline_layout.deinit();

    const slug_attributes = toAttributes(gpu.SlugVertex);
    const vertex_buffers: []const wgpu.RenderPipeline.VertexBufferLayout = &.{.{
        .array_stride = @sizeOf(gpu.SlugVertex),
        .step_mode = .vertex,
        .attributes = &slug_attributes,
    }};

    const pipeline = try ctx.device.createRenderPipeline(.{
        .label = "slug_pipeline",
        .layout = pipeline_layout,
        .vertex = .{ .module = shader_module, .entry_point = "vs_main", .buffers = vertex_buffers },
        .fragment = .{
            .module = shader_module,
            .entry_point = if (ctx.surface_is_srgb) "fs_main" else "fs_main_srgb_encode",
            .targets = &.{.{
                .format = ctx.surface_format,
                .blend = .{
                    .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha, .operation = .add },
                    .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha, .operation = .add },
                },
            }},
        },
    });

    self.* = .{
        .allocator = allocator,
        .kind = .text,
        .render_pipeline = pipeline,
        .bind_group_layout = bgl,
        .bind_group = null,
        .uniform_buffer = uniform_buffer,
        .uniform_size = uniform_size,
        .queue = ctx.queue,
        .device = ctx.device,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = gpu.Pipeline.VTable{
    .deinit = &deinit,
    .updateViewport = &updateViewport,
    .bindTexture = &bindTexture,
    .bindCurveBand = &bindCurveBand,
};

fn deinit(ptr: *anyopaque) void {
    const self: *Pipeline = @ptrCast(@alignCast(ptr));
    self.render_pipeline.deinit();
    self.bind_group_layout.deinit();
    if (self.bind_group) |bg| bg.deinit();
    self.uniform_buffer.deinit();
    self.allocator.destroy(self);
}

fn updateViewport(ptr: *anyopaque, width: u32, height: u32) void {
    const self: *Pipeline = @ptrCast(@alignCast(ptr));
    const w_f: f32 = @floatFromInt(width);
    const h_f: f32 = @floatFromInt(height);
    switch (self.kind) {
        .vertex, .instance => {
            const viewport = [2]f32{ w_f, h_f };
            self.queue.writeBuffer(f32, self.uniform_buffer, 0, &viewport);
        },
        .text => {
            // Screen-space pos.xy -> clip space orthographic projection,
            // y-flipped to match the rest of the UI (window y-down).
            const u = SlugUniforms{
                .mvp_row0 = .{ 2.0 / w_f, 0, 0, -1 },
                .mvp_row1 = .{ 0, -2.0 / h_f, 0, 1 },
                .mvp_row2 = .{ 0, 0, 1, 0 },
                .mvp_row3 = .{ 0, 0, 0, 1 },
                .viewport = .{ w_f, h_f, 0, 0 },
            };
            self.queue.writeBuffer(SlugUniforms, self.uniform_buffer, 0, &.{u});
        },
    }
}

fn bindTexture(ptr: *anyopaque, texture_ptr: *gpu.Texture, sampler_ptr: *gpu.Sampler) void {
    const self: *Pipeline = @ptrCast(@alignCast(ptr));
    if (self.kind == .text) return; // text pipeline uses bindCurveBand

    const tex: *Texture = @ptrCast(@alignCast(texture_ptr.ptr));
    const samp: *Sampler = @ptrCast(@alignCast(sampler_ptr.ptr));

    if (self.bind_group) |bg| bg.deinit();

    self.bind_group = self.device.createBindGroup(.{
        .label = "unified_bg",
        .layout = self.bind_group_layout,
        .entries = &.{
            .{ .binding = 0, .buffer = self.uniform_buffer, .size = self.uniform_size },
            .{ .binding = 1, .texture_view = tex.view },
            .{ .binding = 2, .sampler = samp.sampler },
        },
    }) catch @panic("Failed to recreate bind group for texture binding");
}

fn bindCurveBand(ptr: *anyopaque, curve_tex_ptr: *gpu.Texture, band_tex_ptr: *gpu.Texture) void {
    const self: *Pipeline = @ptrCast(@alignCast(ptr));
    if (self.kind != .text) return;

    const ctex: *Texture = @ptrCast(@alignCast(curve_tex_ptr.ptr));
    const btex: *Texture = @ptrCast(@alignCast(band_tex_ptr.ptr));

    if (self.bind_group) |bg| bg.deinit();

    self.bind_group = self.device.createBindGroup(.{
        .label = "slug_bg",
        .layout = self.bind_group_layout,
        .entries = &.{
            .{ .binding = 0, .buffer = self.uniform_buffer, .size = self.uniform_size },
            .{ .binding = 1, .texture_view = ctex.view },
            .{ .binding = 2, .texture_view = btex.view },
        },
    }) catch @panic("Failed to recreate slug bind group");
}

fn toAttributes(comptime T: type) [@typeInfo(T).@"struct".fields.len]wgpu.RenderPipeline.VertexAttribute {
    const fields = @typeInfo(T).@"struct".fields;
    var attrs: [fields.len]wgpu.RenderPipeline.VertexAttribute = undefined;

    inline for (fields, 0..) |field, i| {
        attrs[i] = .{
            .shader_location = i,
            .offset = @offsetOf(T, field.name),
            .format = switch (@typeInfo(field.type)) {
                inline .array => |arr| switch (arr.child) {
                    inline f32 => switch (arr.len) {
                        inline 2 => .float32x2,
                        inline 3 => .float32x3,
                        inline 4 => .float32x4,
                        inline else => unreachable,
                    },
                    inline else => unreachable,
                },
                inline .float => |float| switch (float.bits) {
                    inline 16 => .float16,
                    inline 32 => .float32,
                    inline else => unreachable,
                },
                inline else => unreachable,
            },
        };
    }

    return attrs;
}
