const std = @import("std");
const wgpu = @import("wgpu");
const gpu = @import("gpu");
const Context = @import("Context.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const Pipeline = @This();

const ui_primitives_src = @embedFile("shaders/ui_primitives.wgsl");

allocator: std.mem.Allocator,
render_pipeline: wgpu.RenderPipeline,
bind_group_layout: wgpu.BindGroupLayout,
bind_group: ?wgpu.BindGroup,
uniform_buffer: wgpu.Buffer,
queue: wgpu.Queue,
device: wgpu.Device,

pub fn create(allocator: std.mem.Allocator, ctx: *Context, desc: gpu.Pipeline.Desc) !gpu.Pipeline {
    const self = try allocator.create(Pipeline);
    errdefer allocator.destroy(self);

    const shader_module = try wgpu.ShaderModule.init(ctx.device.device, .{ .wgsl = ui_primitives_src });
    defer shader_module.deinit();

    const uniform_buffer = try ctx.device.createBuffer(.{
        .usage = .{ .uniform = true, .copy_dst = true },
        .size = 2 * @sizeOf(f32),
        .label = "",
    });

    const bgl_entries = &[_]wgpu.BindGroupLayout.Entry{
        .{
            .binding = 0,
            .visibility = .{ .vertex = true },
            .buffer = .{ .binding_type = .uniform },
        },
        .{
            .binding = 1,
            .visibility = .{ .fragment = true },
            .texture = .{ .sample_type = .float, .view_dimension = .@"2d" },
        },
        .{
            .binding = 2,
            .visibility = .{ .fragment = true },
            .sampler = .{ .binding_type = .filtering },
        },
    };

    const bgl = try ctx.device.createBindGroupLayout(.{
        .label = "unified_bgl",
        .entries = bgl_entries,
    });

    const pipeline_layout = try ctx.device.createPipelineLayout("unified_pipeline_layout", &.{bgl});
    defer pipeline_layout.deinit();

    const vertex_attributes = toAttributes(gpu.Vertex);
    const instance_attributes = toAttributes(gpu.Instance);

    const vertex_buffers: []const wgpu.RenderPipeline.VertexBufferLayout = switch (desc.kind) {
        .vertex => &.{
            .{
                .array_stride = @sizeOf(gpu.Vertex),
                .step_mode = .vertex,
                .attributes = &vertex_attributes,
            },
        },
        .instance => &.{
            .{
                .array_stride = @sizeOf(gpu.Instance),
                .step_mode = .instance,
                .attributes = &instance_attributes,
            },
        },
    };

    const vs_entry: []const u8 = switch (desc.kind) {
        .vertex => "vs_main",
        .instance => "vs_instance_main",
    };

    const pipeline = try ctx.device.createRenderPipeline(.{
        .label = "unified_pipeline",
        .layout = pipeline_layout,
        .vertex = .{
            .module = shader_module,
            .entry_point = vs_entry,
            .buffers = vertex_buffers,
        },
        .fragment = .{
            .module = shader_module,
            .entry_point = if (ctx.surface_is_srgb) "fs_main" else "fs_main_srgb_encode",
            .targets = &.{
                .{
                    .format = ctx.surface_format,
                    .blend = .{
                        .color = .{
                            .src_factor = .src_alpha,
                            .dst_factor = .one_minus_src_alpha,
                            .operation = .add,
                        },
                        .alpha = .{
                            .src_factor = .one,
                            .dst_factor = .one_minus_src_alpha,
                            .operation = .add,
                        },
                    },
                },
            },
        },
    });

    self.* = .{
        .allocator = allocator,
        .render_pipeline = pipeline,
        .bind_group_layout = bgl,
        .bind_group = null,
        .uniform_buffer = uniform_buffer,
        .queue = ctx.queue,
        .device = ctx.device,
    };

    return .{ .ptr = self, .vtable = &vtable };
}

const vtable = gpu.Pipeline.VTable{
    .deinit = &deinit,
    .updateViewport = &updateViewport,
    .bindTexture = &bindTexture,
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
    const viewport = [2]f32{ @floatFromInt(width), @floatFromInt(height) };
    self.queue.writeBuffer(f32, self.uniform_buffer, 0, &viewport);
}

fn bindTexture(ptr: *anyopaque, texture_ptr: *gpu.Texture, sampler_ptr: *gpu.Sampler) void {
    const self: *Pipeline = @ptrCast(@alignCast(ptr));

    const tex: *Texture = @ptrCast(@alignCast(texture_ptr.ptr));
    const samp: *Sampler = @ptrCast(@alignCast(sampler_ptr.ptr));

    if (self.bind_group) |bg| bg.deinit();

    self.bind_group = self.device.createBindGroup(.{
        .label = "unified_bg",
        .layout = self.bind_group_layout,
        .entries = &.{
            .{ .binding = 0, .buffer = self.uniform_buffer, .size = @sizeOf([2]f32) },
            .{ .binding = 1, .texture_view = tex.view },
            .{ .binding = 2, .sampler = samp.sampler },
        },
    }) catch @panic("Failed to recreate bind group for texture binding");
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
