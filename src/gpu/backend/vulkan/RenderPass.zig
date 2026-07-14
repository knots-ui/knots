const std = @import("std");
const vk = @import("vk");
const Device = @import("Device.zig");
const Surface = @import("Surface.zig");
const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");

const RenderPass = @This();

command_buffer: vk.CommandBuffer,
vkd: vk.DeviceWrapper,
image: vk.Image,
current_pipeline_layout: vk.PipelineLayout,
debug_label: bool,

pub const LoadOp = enum { clear, load };
pub const StoreOp = enum { store, discard };

pub const ColorAttachment = struct {
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    target: ?*Texture = null,
};

pub const Desc = struct {
    label: []const u8 = "",
    color_attachment: ColorAttachment = .{},
};

pub fn create(command_buffer: vk.CommandBuffer, device: *Device, surface: *Surface, image_index: u32, desc: Desc) RenderPass {
    const ca = desc.color_attachment;

    const image = surface.swapchain_images[image_index];
    var debug_label = false;
    if (device.debug_utils and desc.label.len != 0) {
        var label_buffer: [256]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&label_buffer, "{s}", .{desc.label}, 0x00)) |label| {
            device.vkd.cmdBeginDebugUtilsLabelEXT(command_buffer, &.{ .p_label_name = label, .color = .{ 0.2, 0.6, 1.0, 1.0 } });
            debug_label = true;
        } else |_| {}
    }
    device.vkd.cmdPipelineBarrier2(command_buffer, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[_]vk.ImageMemoryBarrier2{.{
            .dst_stage_mask = .{ .color_attachment_output = true },
            .dst_access_mask = .{ .color_attachment_write = true },
            .old_layout = .undefined,
            .new_layout = .color_attachment_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        }},
    });

    device.vkd.cmdBeginRendering(command_buffer, &.{
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = surface.swapchain_extent },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = &[_]vk.RenderingAttachmentInfo{.{
            .image_view = surface.swapchain_views[image_index],
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{
                ca.clear_color[0], ca.clear_color[1], ca.clear_color[2], ca.clear_color[3],
            } } },
        }},
    });
    device.vkd.cmdSetViewport(command_buffer, 0, &.{.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(surface.swapchain_extent.width),
        .height = @floatFromInt(surface.swapchain_extent.height),
        .min_depth = 0,
        .max_depth = 1,
    }});
    device.vkd.cmdSetScissor(command_buffer, 0, &.{.{
        .offset = .{ .x = 0, .y = 0 },
        .extent = surface.swapchain_extent,
    }});

    return .{
        .command_buffer = command_buffer,
        .vkd = device.vkd,
        .image = image,
        .current_pipeline_layout = .null_handle,
        .debug_label = debug_label,
    };
}

pub fn end(self: *RenderPass) void {
    self.vkd.cmdEndRendering(self.command_buffer);
    self.vkd.cmdPipelineBarrier2(self.command_buffer, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[_]vk.ImageMemoryBarrier2{.{
            .src_stage_mask = .{ .color_attachment_output = true },
            .src_access_mask = .{ .color_attachment_write = true },
            .old_layout = .color_attachment_optimal,
            .new_layout = .present_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresource_range = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
        }},
    });
    if (self.debug_label) self.vkd.cmdEndDebugUtilsLabelEXT(self.command_buffer);
}

pub fn bindPipeline(self: *RenderPass, pipeline: *const Pipeline) void {
    self.current_pipeline_layout = pipeline.pipeline_layout;
    self.vkd.cmdBindPipeline(self.command_buffer, .graphics, pipeline.pipeline);
}

pub fn setBindGroup(self: *RenderPass, group_index: u32, group: *const BindGroup) void {
    self.vkd.cmdBindDescriptorSets(
        self.command_buffer,
        .graphics,
        self.current_pipeline_layout,
        group_index,
        &[_]vk.DescriptorSet{group.descriptor_set},
        null,
    );
}

pub fn setVertexBuffer(self: *RenderPass, slot: u32, buf: *const Buffer, offset: usize, size: usize) void {
    std.debug.assert(offset <= buf.size and size <= buf.size - offset);
    self.vkd.cmdBindVertexBuffers(self.command_buffer, slot, &.{buf.buffer}, &.{@as(vk.DeviceSize, @intCast(offset))});
}

pub fn setIndexBuffer(self: *RenderPass, buf: *const Buffer, offset: usize, size: usize) void {
    std.debug.assert(offset <= buf.size and size <= buf.size - offset);
    self.vkd.cmdBindIndexBuffer(self.command_buffer, buf.buffer, @intCast(offset), .uint32);
}

pub fn setScissorRect(self: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
    self.vkd.cmdSetScissor(self.command_buffer, 0, &.{.{
        .offset = .{ .x = @intCast(x), .y = @intCast(y) },
        .extent = .{ .width = w, .height = h },
    }});
}

pub fn setViewport(self: *RenderPass, x: f32, y: f32, width: f32, height: f32) void {
    self.vkd.cmdSetViewport(self.command_buffer, 0, &.{.{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .min_depth = 0,
        .max_depth = 1,
    }});
}

pub fn draw(self: *RenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
    self.vkd.cmdDraw(self.command_buffer, vertex_count, instance_count, first_vertex, first_instance);
}

pub fn drawIndexed(self: *RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    self.vkd.cmdDrawIndexed(self.command_buffer, index_count, instance_count, first_index, base_vertex, first_instance);
}
