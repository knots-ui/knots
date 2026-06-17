const std = @import("std");
const vk = @import("vk");
const Context = @import("Context.zig");
const CommonPipeline = @import("gpu").Pipeline;

const Pipeline = @This();

allocator: std.mem.Allocator,
pipeline: vk.Pipeline,
pipeline_layout: vk.PipelineLayout,
descriptor_set_layouts: []vk.DescriptorSetLayout,
vkd: vk.DeviceWrapper,
device: vk.Device,

pub fn create(allocator: std.mem.Allocator, ctx: *Context, desc: CommonPipeline.Desc) !Pipeline {
    const vkd = ctx.vkd;
    const device = ctx.device;

    const spirv = switch (desc.shader) {
        .spirv => |s| s,
        .wgsl => return error.UnsupportedShaderSource,
    };

    const dsls = try allocator.alloc(vk.DescriptorSetLayout, desc.bind_group_layouts.len);
    errdefer allocator.free(dsls);
    var dsls_created: usize = 0;
    errdefer for (dsls[0..dsls_created]) |dsl| vkd.destroyDescriptorSetLayout(device, dsl, null);

    var binding_buf: [16]vk.DescriptorSetLayoutBinding = undefined;
    for (desc.bind_group_layouts, 0..) |bgl, i| {
        if (bgl.entries.len > binding_buf.len) return error.TooManyBindGroupEntries;
        for (bgl.entries, 0..) |e, j| {
            binding_buf[j] = .{
                .binding = e.binding,
                .descriptor_type = toVkDescriptorType(e.type),
                .descriptor_count = 1,
                .stage_flags = .{
                    .vertex_bit = e.visibility.vertex,
                    .fragment_bit = e.visibility.fragment,
                },
                .p_immutable_samplers = null,
            };
        }
        dsls[i] = try vkd.createDescriptorSetLayout(device, &.{
            .binding_count = @intCast(bgl.entries.len),
            .p_bindings = binding_buf[0..bgl.entries.len].ptr,
        }, null);
        dsls_created += 1;
    }

    const pipeline_layout = try vkd.createPipelineLayout(device, &.{
        .set_layout_count = @intCast(dsls.len),
        .p_set_layouts = dsls.ptr,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    }, null);
    errdefer vkd.destroyPipelineLayout(device, pipeline_layout, null);

    const vert_module = try vkd.createShaderModule(device, &.{
        .code_size = spirv.vs.len,
        .p_code = @ptrCast(@alignCast(spirv.vs.ptr)),
    }, null);
    defer vkd.destroyShaderModule(device, vert_module, null);

    const frag_module = try vkd.createShaderModule(device, &.{
        .code_size = spirv.fs.len,
        .p_code = @ptrCast(@alignCast(spirv.fs.ptr)),
    }, null);
    defer vkd.destroyShaderModule(device, frag_module, null);

    var apply_srgb_encode: u32 = 0;
    var spec_map: [1]vk.SpecializationMapEntry = undefined;
    var frag_spec_info: vk.SpecializationInfo = undefined;
    const frag_spec_ptr: ?*const vk.SpecializationInfo = if (spirv.srgb_encode_constant) |cid| blk: {
        apply_srgb_encode = if (ctx.swapchain_is_srgb) 0 else 1;
        spec_map[0] = .{ .constant_id = cid, .offset = 0, .size = @sizeOf(u32) };
        frag_spec_info = .{
            .map_entry_count = 1,
            .p_map_entries = &spec_map,
            .data_size = @sizeOf(u32),
            .p_data = &apply_srgb_encode,
        };
        break :blk &frag_spec_info;
    } else null;

    var vk_attr_buf: [16]vk.VertexInputAttributeDescription = undefined;
    var vk_binding_buf: [4]vk.VertexInputBindingDescription = undefined;
    if (desc.vertex_buffers.len > vk_binding_buf.len) return error.TooManyVertexBuffers;
    var attr_total: usize = 0;
    for (desc.vertex_buffers, 0..) |vb, i| {
        if (attr_total + vb.attributes.len > vk_attr_buf.len) return error.TooManyVertexAttributes;
        vk_binding_buf[i] = .{
            .binding = @intCast(i),
            .stride = vb.stride,
            .input_rate = switch (vb.step_mode) {
                .vertex => .vertex,
                .instance => .instance,
            },
        };
        for (vb.attributes) |a| {
            vk_attr_buf[attr_total] = .{
                .location = a.location,
                .binding = @intCast(i),
                .offset = a.offset,
                .format = toVkVertexFormat(a.format),
            };
            attr_total += 1;
        }
    }

    const blend_attachment: vk.PipelineColorBlendAttachmentState = if (desc.color_target.blend) |b| .{
        .blend_enable = .true,
        .src_color_blend_factor = toVkBlendFactor(b.color.src_factor),
        .dst_color_blend_factor = toVkBlendFactor(b.color.dst_factor),
        .color_blend_op = toVkBlendOp(b.color.op),
        .src_alpha_blend_factor = toVkBlendFactor(b.alpha.src_factor),
        .dst_alpha_blend_factor = toVkBlendFactor(b.alpha.dst_factor),
        .alpha_blend_op = toVkBlendOp(b.alpha.op),
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    } else .{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    var vs_entry_buf: [64]u8 = undefined;
    var fs_entry_buf: [64]u8 = undefined;
    if (spirv.vs_entry.len >= vs_entry_buf.len or spirv.fs_entry.len >= fs_entry_buf.len) {
        return error.EntryPointNameTooLong;
    }
    @memcpy(vs_entry_buf[0..spirv.vs_entry.len], spirv.vs_entry);
    vs_entry_buf[spirv.vs_entry.len] = 0;
    @memcpy(fs_entry_buf[0..spirv.fs_entry.len], spirv.fs_entry);
    fs_entry_buf[spirv.fs_entry.len] = 0;

    var vk_pipeline: [1]vk.Pipeline = undefined;
    _ = try vkd.createGraphicsPipelines(device, .null_handle, &.{.{
        .stage_count = 2,
        .p_stages = &[_]vk.PipelineShaderStageCreateInfo{
            .{ .stage = .{ .vertex_bit = true }, .module = vert_module, .p_name = @ptrCast(&vs_entry_buf) },
            .{ .stage = .{ .fragment_bit = true }, .module = frag_module, .p_name = @ptrCast(&fs_entry_buf), .p_specialization_info = frag_spec_ptr },
        },
        .p_vertex_input_state = &.{
            .vertex_binding_description_count = @intCast(desc.vertex_buffers.len),
            .p_vertex_binding_descriptions = vk_binding_buf[0..desc.vertex_buffers.len].ptr,
            .vertex_attribute_description_count = @intCast(attr_total),
            .p_vertex_attribute_descriptions = vk_attr_buf[0..attr_total].ptr,
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
            .p_attachments = &[_]vk.PipelineColorBlendAttachmentState{blend_attachment},
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

    return .{
        .allocator = allocator,
        .pipeline = vk_pipeline[0],
        .pipeline_layout = pipeline_layout,
        .descriptor_set_layouts = dsls,
        .vkd = vkd,
        .device = device,
    };
}

pub fn deinit(self: *Pipeline) void {
    self.vkd.destroyPipeline(self.device, self.pipeline, null);
    self.vkd.destroyPipelineLayout(self.device, self.pipeline_layout, null);
    for (self.descriptor_set_layouts) |dsl| self.vkd.destroyDescriptorSetLayout(self.device, dsl, null);
    self.allocator.free(self.descriptor_set_layouts);
}

pub fn descriptorSetLayout(self: *const Pipeline, index: u32) vk.DescriptorSetLayout {
    return self.descriptor_set_layouts[index];
}

fn toVkDescriptorType(t: CommonPipeline.BindingType) vk.DescriptorType {
    return switch (t) {
        .uniform_buffer => .uniform_buffer,
        .read_only_storage_buffer => .storage_buffer,
        .sampled_texture => .sampled_image,
        .sampler => .sampler,
    };
}

fn toVkVertexFormat(f: CommonPipeline.VertexFormat) vk.Format {
    return switch (f) {
        .f32 => .r32_sfloat,
        .f32x2 => .r32g32_sfloat,
        .f32x3 => .r32g32b32_sfloat,
        .f32x4 => .r32g32b32a32_sfloat,
    };
}

fn toVkBlendFactor(f: CommonPipeline.BlendFactor) vk.BlendFactor {
    return switch (f) {
        .zero => .zero,
        .one => .one,
        .src_alpha => .src_alpha,
        .one_minus_src_alpha => .one_minus_src_alpha,
    };
}

fn toVkBlendOp(o: CommonPipeline.BlendOp) vk.BlendOp {
    return switch (o) {
        .add => .add,
    };
}
