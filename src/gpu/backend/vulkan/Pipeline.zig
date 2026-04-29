const std = @import("std");
const vk = @import("vk");
const gpu = @import("gpu");
const Context = @import("Context.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const ui_primitives_vert_spv align(@alignOf(u32)) = @embedFile("ui_primitives_vertex_shader").*;
const ui_primitives_instance_vert_spv align(@alignOf(u32)) = @embedFile("ui_primitives_instance_vertex_shader").*;
const ui_primitives_frag_spv align(@alignOf(u32)) = @embedFile("ui_primitives_fragment_shader").*;
const slug_vert_spv align(@alignOf(u32)) = @embedFile("slug_vertex_shader").*;
const slug_frag_spv align(@alignOf(u32)) = @embedFile("slug_fragment_shader").*;

const ui_primitives_vertex_attributes = toVkAttributes(gpu.Vertex);
const ui_primitives_instance_attributes = toVkAttributes(gpu.Instance);
const slug_attributes = toVkAttributes(gpu.SlugVertex);

const SlugUniforms = extern struct {
    mvp_row0: [4]f32,
    mvp_row1: [4]f32,
    mvp_row2: [4]f32,
    mvp_row3: [4]f32,
    viewport: [4]f32,
};

const vtable = gpu.Pipeline.VTable{
    .deinit = &deinit,
    .updateViewport = &updateViewport,
    .bindTexture = &bindTexture,
    .bindCurveBand = &bindCurveBand,
};

const Pipeline = @This();

const SlugDescriptors = struct {
    set_layout: vk.DescriptorSetLayout,
    descriptor_set: vk.DescriptorSet,
    bound: bool,
};

allocator: std.mem.Allocator,
kind: gpu.Pipeline.Kind,
pipeline: vk.Pipeline,
pipeline_layout: vk.PipelineLayout,
uniform_descriptor_set_layout: vk.DescriptorSetLayout,
uniform_descriptor_sets: []vk.DescriptorSet,
uniform_buffers: []vk.Buffer,
uniform_memories: []vk.DeviceMemory,
uniform_mapped: []*anyopaque,
uniform_size: usize,
current_texture_ds: vk.DescriptorSet,
slug_descriptors: ?SlugDescriptors,
ctx: *Context,
vkd: Context.DeviceDispatch,
device: vk.Device,

pub fn create(allocator: std.mem.Allocator, ctx: *Context, desc: gpu.Pipeline.Desc) !gpu.Pipeline {
    return switch (desc.kind) {
        .vertex, .instance => createPrimitives(allocator, ctx, desc),
        .text => createSlug(allocator, ctx),
    };
}

fn createPrimitives(allocator: std.mem.Allocator, ctx: *Context, desc: gpu.Pipeline.Desc) !gpu.Pipeline {
    const vkd = ctx.vkd;
    const device = ctx.device;

    const frame_count = ctx.swapchain_images.len;
    const uniform_size: usize = @sizeOf([2]f32);

    const uniform_buffers = try allocator.alloc(vk.Buffer, frame_count);
    errdefer allocator.free(uniform_buffers);
    const uniform_memories = try allocator.alloc(vk.DeviceMemory, frame_count);
    errdefer allocator.free(uniform_memories);
    const uniform_mapped = try allocator.alloc(*anyopaque, frame_count);
    errdefer allocator.free(uniform_mapped);
    var ub_created: usize = 0;
    errdefer {
        for (0..ub_created) |i| {
            vkd.destroyBuffer(device, uniform_buffers[i], null);
            vkd.freeMemory(device, uniform_memories[i], null);
        }
    }
    for (0..frame_count) |i| {
        uniform_buffers[i] = try vkd.createBuffer(device, &.{
            .size = uniform_size,
            .usage = .{ .uniform_buffer_bit = true },
            .sharing_mode = .exclusive,
        }, null);
        const mem_reqs = vkd.getBufferMemoryRequirements(device, uniform_buffers[i]);
        uniform_memories[i] = try vkd.allocateMemory(device, &.{
            .allocation_size = mem_reqs.size,
            .memory_type_index = try ctx.findMemoryType(mem_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }),
        }, null);
        try vkd.bindBufferMemory(device, uniform_buffers[i], uniform_memories[i], 0);
        uniform_mapped[i] = (try vkd.mapMemory(device, uniform_memories[i], 0, uniform_size, .{})).?;
        ub_created += 1;
    }

    const uniform_descriptor_set_layout = try vkd.createDescriptorSetLayout(device, &.{
        .binding_count = 1,
        .p_bindings = &[_]vk.DescriptorSetLayoutBinding{.{
            .binding = 0,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .vertex_bit = true },
            .p_immutable_samplers = null,
        }},
    }, null);
    errdefer vkd.destroyDescriptorSetLayout(device, uniform_descriptor_set_layout, null);

    const uniform_descriptor_sets = try allocator.alloc(vk.DescriptorSet, frame_count);
    errdefer allocator.free(uniform_descriptor_sets);
    for (0..frame_count) |i| {
        uniform_descriptor_sets[i] = try ctx.allocateDescriptorSet(uniform_descriptor_set_layout);
        vkd.updateDescriptorSets(device, &.{.{
            .dst_set = uniform_descriptor_sets[i],
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .uniform_buffer,
            .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{ .buffer = uniform_buffers[i], .offset = 0, .range = uniform_size }},
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        }}, null);
    }

    const pipeline_layout = try vkd.createPipelineLayout(device, &.{
        .set_layout_count = 2,
        .p_set_layouts = &[_]vk.DescriptorSetLayout{
            uniform_descriptor_set_layout,
            ctx.texture_descriptor_set_layout,
        },
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    }, null);
    errdefer vkd.destroyPipelineLayout(device, pipeline_layout, null);

    const vert_spv: []align(@alignOf(u32)) const u8 = switch (desc.kind) {
        .vertex => &ui_primitives_vert_spv,
        .instance => &ui_primitives_instance_vert_spv,
        .text => unreachable,
    };
    const vert_module = try vkd.createShaderModule(device, &.{
        .code_size = vert_spv.len,
        .p_code = @ptrCast(@alignCast(vert_spv.ptr)),
    }, null);
    defer vkd.destroyShaderModule(device, vert_module, null);

    const vk_vertex_stride: u32 = switch (desc.kind) {
        .vertex => @sizeOf(gpu.Vertex),
        .instance => @sizeOf(gpu.Instance),
        .text => unreachable,
    };
    const vk_input_rate: vk.VertexInputRate = switch (desc.kind) {
        .vertex => .vertex,
        .instance => .instance,
        .text => unreachable,
    };
    const vk_attributes: []const vk.VertexInputAttributeDescription = switch (desc.kind) {
        .vertex => &ui_primitives_vertex_attributes,
        .instance => &ui_primitives_instance_attributes,
        .text => unreachable,
    };

    const frag_module = try vkd.createShaderModule(device, &.{
        .code_size = ui_primitives_frag_spv.len,
        .p_code = @ptrCast(@alignCast(&ui_primitives_frag_spv)),
    }, null);
    defer vkd.destroyShaderModule(device, frag_module, null);

    const apply_srgb_encode: u32 = if (ctx.swapchain_is_srgb) 0 else 1;
    const spec_map = [_]vk.SpecializationMapEntry{.{ .constant_id = 0, .offset = 0, .size = @sizeOf(u32) }};
    const frag_spec_info = vk.SpecializationInfo{
        .map_entry_count = spec_map.len,
        .p_map_entries = &spec_map,
        .data_size = @sizeOf(u32),
        .p_data = &apply_srgb_encode,
    };

    const pipeline = try createGraphicsPipeline(
        ctx,
        pipeline_layout,
        vert_module,
        frag_module,
        &frag_spec_info,
        vk_vertex_stride,
        vk_input_rate,
        vk_attributes,
    );

    const self = try allocator.create(Pipeline);
    self.* = .{
        .allocator = allocator,
        .kind = desc.kind,
        .pipeline = pipeline,
        .pipeline_layout = pipeline_layout,
        .uniform_descriptor_set_layout = uniform_descriptor_set_layout,
        .uniform_descriptor_sets = uniform_descriptor_sets,
        .uniform_buffers = uniform_buffers,
        .uniform_memories = uniform_memories,
        .uniform_mapped = uniform_mapped,
        .uniform_size = uniform_size,
        .current_texture_ds = .null_handle,
        .slug_descriptors = null,
        .ctx = ctx,
        .vkd = vkd,
        .device = device,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

fn createSlug(allocator: std.mem.Allocator, ctx: *Context) !gpu.Pipeline {
    const vkd = ctx.vkd;
    const device = ctx.device;

    const frame_count = ctx.swapchain_images.len;
    const uniform_size: usize = @sizeOf(SlugUniforms);

    const uniform_buffers = try allocator.alloc(vk.Buffer, frame_count);
    errdefer allocator.free(uniform_buffers);
    const uniform_memories = try allocator.alloc(vk.DeviceMemory, frame_count);
    errdefer allocator.free(uniform_memories);
    const uniform_mapped = try allocator.alloc(*anyopaque, frame_count);
    errdefer allocator.free(uniform_mapped);
    var ub_created: usize = 0;
    errdefer {
        for (0..ub_created) |i| {
            vkd.destroyBuffer(device, uniform_buffers[i], null);
            vkd.freeMemory(device, uniform_memories[i], null);
        }
    }
    for (0..frame_count) |i| {
        uniform_buffers[i] = try vkd.createBuffer(device, &.{
            .size = uniform_size,
            .usage = .{ .uniform_buffer_bit = true },
            .sharing_mode = .exclusive,
        }, null);
        const mem_reqs = vkd.getBufferMemoryRequirements(device, uniform_buffers[i]);
        uniform_memories[i] = try vkd.allocateMemory(device, &.{
            .allocation_size = mem_reqs.size,
            .memory_type_index = try ctx.findMemoryType(mem_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }),
        }, null);
        try vkd.bindBufferMemory(device, uniform_buffers[i], uniform_memories[i], 0);
        uniform_mapped[i] = (try vkd.mapMemory(device, uniform_memories[i], 0, uniform_size, .{})).?;
        ub_created += 1;
    }

    const uniform_descriptor_set_layout = try vkd.createDescriptorSetLayout(device, &.{
        .binding_count = 1,
        .p_bindings = &[_]vk.DescriptorSetLayoutBinding{.{
            .binding = 0,
            .descriptor_type = .uniform_buffer,
            .descriptor_count = 1,
            .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
            .p_immutable_samplers = null,
        }},
    }, null);
    errdefer vkd.destroyDescriptorSetLayout(device, uniform_descriptor_set_layout, null);

    const uniform_descriptor_sets = try allocator.alloc(vk.DescriptorSet, frame_count);
    errdefer allocator.free(uniform_descriptor_sets);
    for (0..frame_count) |i| {
        uniform_descriptor_sets[i] = try ctx.allocateDescriptorSet(uniform_descriptor_set_layout);
        vkd.updateDescriptorSets(device, &.{.{
            .dst_set = uniform_descriptor_sets[i],
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .uniform_buffer,
            .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{ .buffer = uniform_buffers[i], .offset = 0, .range = uniform_size }},
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        }}, null);
    }

    const slug_set_layout = try vkd.createDescriptorSetLayout(device, &.{
        .binding_count = 2,
        .p_bindings = &[_]vk.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .sampled_image, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true }, .p_immutable_samplers = null },
        },
    }, null);
    errdefer vkd.destroyDescriptorSetLayout(device, slug_set_layout, null);

    const slug_descriptor_set = try ctx.allocateDescriptorSet(slug_set_layout);

    const pipeline_layout = try vkd.createPipelineLayout(device, &.{
        .set_layout_count = 2,
        .p_set_layouts = &[_]vk.DescriptorSetLayout{ uniform_descriptor_set_layout, slug_set_layout },
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    }, null);
    errdefer vkd.destroyPipelineLayout(device, pipeline_layout, null);

    const vert_module = try vkd.createShaderModule(device, &.{
        .code_size = slug_vert_spv.len,
        .p_code = @ptrCast(@alignCast(&slug_vert_spv)),
    }, null);
    defer vkd.destroyShaderModule(device, vert_module, null);

    const frag_module = try vkd.createShaderModule(device, &.{
        .code_size = slug_frag_spv.len,
        .p_code = @ptrCast(@alignCast(&slug_frag_spv)),
    }, null);
    defer vkd.destroyShaderModule(device, frag_module, null);

    const apply_srgb_encode: u32 = if (ctx.swapchain_is_srgb) 0 else 1;
    const spec_map = [_]vk.SpecializationMapEntry{.{ .constant_id = 0, .offset = 0, .size = @sizeOf(u32) }};
    const frag_spec_info = vk.SpecializationInfo{
        .map_entry_count = spec_map.len,
        .p_map_entries = &spec_map,
        .data_size = @sizeOf(u32),
        .p_data = &apply_srgb_encode,
    };

    const pipeline = try createGraphicsPipeline(
        ctx,
        pipeline_layout,
        vert_module,
        frag_module,
        &frag_spec_info,
        @sizeOf(gpu.SlugVertex),
        .vertex,
        &slug_attributes,
    );

    const self = try allocator.create(Pipeline);
    self.* = .{
        .allocator = allocator,
        .kind = .text,
        .pipeline = pipeline,
        .pipeline_layout = pipeline_layout,
        .uniform_descriptor_set_layout = uniform_descriptor_set_layout,
        .uniform_descriptor_sets = uniform_descriptor_sets,
        .uniform_buffers = uniform_buffers,
        .uniform_memories = uniform_memories,
        .uniform_mapped = uniform_mapped,
        .uniform_size = uniform_size,
        .current_texture_ds = .null_handle,
        .slug_descriptors = .{
            .set_layout = slug_set_layout,
            .descriptor_set = slug_descriptor_set,
            .bound = false,
        },
        .ctx = ctx,
        .vkd = vkd,
        .device = device,
    };
    return .{ .ptr = self, .vtable = &vtable };
}

fn createGraphicsPipeline(
    ctx: *Context,
    pipeline_layout: vk.PipelineLayout,
    vert_module: vk.ShaderModule,
    frag_module: vk.ShaderModule,
    frag_spec_info: *const vk.SpecializationInfo,
    vertex_stride: u32,
    input_rate: vk.VertexInputRate,
    attributes: []const vk.VertexInputAttributeDescription,
) !vk.Pipeline {
    var vk_pipeline: [1]vk.Pipeline = undefined;
    _ = try ctx.vkd.createGraphicsPipelines(ctx.device, .null_handle, &.{.{
        .stage_count = 2,
        .p_stages = &[_]vk.PipelineShaderStageCreateInfo{
            .{ .stage = .{ .vertex_bit = true }, .module = vert_module, .p_name = "main" },
            .{ .stage = .{ .fragment_bit = true }, .module = frag_module, .p_name = "main", .p_specialization_info = frag_spec_info },
        },
        .p_vertex_input_state = &.{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = &[_]vk.VertexInputBindingDescription{.{
                .binding = 0,
                .stride = vertex_stride,
                .input_rate = input_rate,
            }},
            .vertex_attribute_description_count = @intCast(attributes.len),
            .p_vertex_attribute_descriptions = attributes.ptr,
        },
        .p_input_assembly_state = &.{ .topology = .triangle_list, .primitive_restart_enable = .false },
        .p_viewport_state = &.{ .viewport_count = 1, .scissor_count = 1 },
        .p_rasterization_state = &.{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{},
            .front_face = .clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1.0,
        },
        .p_multisample_state = &.{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 1.0,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        },
        .p_depth_stencil_state = null,
        .p_color_blend_state = &.{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = &[_]vk.PipelineColorBlendAttachmentState{.{
                .blend_enable = .true,
                .src_color_blend_factor = .src_alpha,
                .dst_color_blend_factor = .one_minus_src_alpha,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .one_minus_src_alpha,
                .alpha_blend_op = .add,
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            }},
            .blend_constants = .{ 0, 0, 0, 0 },
        },
        .p_dynamic_state = &.{
            .dynamic_state_count = 2,
            .p_dynamic_states = &[_]vk.DynamicState{ .viewport, .scissor },
        },
        .layout = pipeline_layout,
        .render_pass = ctx.render_pass,
        .subpass = 0,
        .base_pipeline_index = -1,
    }}, null, vk_pipeline[0..1]);
    return vk_pipeline[0];
}

fn deinit(ptr: *anyopaque) void {
    const self: *Pipeline = @ptrCast(@alignCast(ptr));
    self.vkd.destroyPipeline(self.device, self.pipeline, null);
    self.vkd.destroyPipelineLayout(self.device, self.pipeline_layout, null);
    self.vkd.destroyDescriptorSetLayout(self.device, self.uniform_descriptor_set_layout, null);
    if (self.slug_descriptors) |sd| {
        self.vkd.destroyDescriptorSetLayout(self.device, sd.set_layout, null);
    }
    for (self.uniform_buffers, self.uniform_memories) |buf, mem| {
        self.vkd.destroyBuffer(self.device, buf, null);
        self.vkd.freeMemory(self.device, mem, null);
    }
    self.allocator.free(self.uniform_buffers);
    self.allocator.free(self.uniform_memories);
    self.allocator.free(self.uniform_mapped);
    self.allocator.free(self.uniform_descriptor_sets);
    self.allocator.destroy(self);
}

fn updateViewport(ptr: *anyopaque, width: u32, height: u32) void {
    const self: *Pipeline = @ptrCast(@alignCast(ptr));
    const w_f: f32 = @floatFromInt(width);
    const h_f: f32 = @floatFromInt(height);
    switch (self.kind) {
        .vertex, .instance => {
            for (self.uniform_mapped) |mapped| {
                const dst: *[2]f32 = @ptrCast(@alignCast(mapped));
                dst.* = .{ w_f, h_f };
            }
        },
        .text => {
            // Vulkan clip space is y-down, so the y row stays positive; pos.xy
            // is already in screen px, so this is a screen→clip ortho.
            const u = SlugUniforms{
                .mvp_row0 = .{ 2.0 / w_f, 0, 0, -1 },
                .mvp_row1 = .{ 0, 2.0 / h_f, 0, -1 },
                .mvp_row2 = .{ 0, 0, 1, 0 },
                .mvp_row3 = .{ 0, 0, 0, 1 },
                .viewport = .{ w_f, h_f, 0, 0 },
            };
            for (self.uniform_mapped) |mapped| {
                const dst: *SlugUniforms = @ptrCast(@alignCast(mapped));
                dst.* = u;
            }
        },
    }
}

fn bindTexture(ptr: *anyopaque, texture: *gpu.Texture, sampler: *gpu.Sampler) void {
    const self: *Pipeline = @ptrCast(@alignCast(ptr));
    if (self.kind == .text) return;
    const vk_texture: *Texture = @ptrCast(@alignCast(texture.ptr));
    const vk_sampler: *Sampler = @ptrCast(@alignCast(sampler.ptr));
    if (!vk_texture.sampler_bound) {
        vk_texture.writeDescriptor(vk_sampler);
        vk_texture.sampler_bound = true;
    }
    self.current_texture_ds = vk_texture.descriptor_set;
}

fn bindCurveBand(ptr: *anyopaque, curve_tex: *gpu.Texture, band_tex: *gpu.Texture) void {
    const self: *Pipeline = @ptrCast(@alignCast(ptr));
    const sd = if (self.slug_descriptors) |*p| p else return;

    const ctex: *Texture = @ptrCast(@alignCast(curve_tex.ptr));
    const btex: *Texture = @ptrCast(@alignCast(band_tex.ptr));

    self.vkd.updateDescriptorSets(self.device, &.{
        .{
            .dst_set = sd.descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .sampled_image,
            .p_image_info = &[_]vk.DescriptorImageInfo{.{
                .sampler = .null_handle,
                .image_view = ctex.image_view,
                .image_layout = .shader_read_only_optimal,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
        .{
            .dst_set = sd.descriptor_set,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .sampled_image,
            .p_image_info = &[_]vk.DescriptorImageInfo{.{
                .sampler = .null_handle,
                .image_view = btex.image_view,
                .image_layout = .shader_read_only_optimal,
            }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    }, null);

    self.current_texture_ds = sd.descriptor_set;
    sd.bound = true;
}

fn toVkAttributes(comptime T: type) [@typeInfo(T).@"struct".fields.len]vk.VertexInputAttributeDescription {
    const fields = @typeInfo(T).@"struct".fields;
    var attrs: [fields.len]vk.VertexInputAttributeDescription = undefined;
    inline for (fields, 0..) |field, i| {
        attrs[i] = .{
            .location = i,
            .binding = 0,
            .offset = @offsetOf(T, field.name),
            .format = switch (@typeInfo(field.type)) {
                .array => |arr| switch (arr.child) {
                    f32 => switch (arr.len) {
                        2 => .r32g32_sfloat,
                        3 => .r32g32b32_sfloat,
                        4 => .r32g32b32a32_sfloat,
                        else => unreachable,
                    },
                    else => unreachable,
                },
                .float => |float| switch (float.bits) {
                    16 => .r16_sfloat,
                    32 => .r32_sfloat,
                    else => unreachable,
                },
                else => unreachable,
            },
        };
    }
    return attrs;
}
