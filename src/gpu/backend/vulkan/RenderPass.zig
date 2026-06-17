const std = @import("std");
const vk = @import("vk");
const Context = @import("Context.zig");
const Buffer = @import("Buffer.zig");
const Pipeline = @import("Pipeline.zig");
const BindGroup = @import("BindGroup.zig");
const Texture = @import("Texture.zig");

const RenderPass = @This();

command_buffer: vk.CommandBuffer,
vkd: vk.DeviceWrapper,
extent: vk.Extent2D,
current_pipeline_layout: vk.PipelineLayout,

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

pub fn create(_: std.mem.Allocator, command_buffer: vk.CommandBuffer, ctx: *Context, desc: Desc) !RenderPass {
    const ca = desc.color_attachment;
    if (ca.target != null) return error.UnsupportedRenderTarget;
    if (ca.load_op != .clear or ca.store_op != .store) return error.UnsupportedRenderPassOperation;

    ctx.vkd.cmdBeginRenderPass(command_buffer, &.{
        .render_pass = ctx.render_pass,
        .framebuffer = ctx.framebuffers[ctx._current_image_index],
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = ctx.swapchain_extent },
        .clear_value_count = 1,
        .p_clear_values = &[_]vk.ClearValue{.{ .color = .{ .float_32 = .{
            ca.clear_color[0], ca.clear_color[1], ca.clear_color[2], ca.clear_color[3],
        } } }},
    }, .@"inline");
    ctx.vkd.cmdSetViewport(command_buffer, 0, &.{.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(ctx.swapchain_extent.width),
        .height = @floatFromInt(ctx.swapchain_extent.height),
        .min_depth = 0,
        .max_depth = 1,
    }});
    ctx.vkd.cmdSetScissor(command_buffer, 0, &.{.{
        .offset = .{ .x = 0, .y = 0 },
        .extent = ctx.swapchain_extent,
    }});

    return .{
        .command_buffer = command_buffer,
        .vkd = ctx.vkd,
        .extent = ctx.swapchain_extent,
        .current_pipeline_layout = .null_handle,
    };
}

pub fn end(self: *RenderPass) void {
    self.vkd.cmdEndRenderPass(self.command_buffer);
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

pub fn setVertexBuffer(self: *RenderPass, slot: u32, buf: *const Buffer, offset: usize, _: usize) void {
    self.vkd.cmdBindVertexBuffers(self.command_buffer, slot, &.{buf.buffer}, &.{@as(vk.DeviceSize, @intCast(offset))});
}

pub fn setIndexBuffer(self: *RenderPass, buf: *const Buffer, offset: usize, _: usize) void {
    self.vkd.cmdBindIndexBuffer(self.command_buffer, buf.buffer, @intCast(offset), .uint32);
}

pub fn setScissorRect(self: *RenderPass, x: u32, y: u32, w: u32, h: u32) void {
    self.vkd.cmdSetScissor(self.command_buffer, 0, &.{.{
        .offset = .{ .x = @intCast(x), .y = @intCast(y) },
        .extent = .{ .width = w, .height = h },
    }});
}

pub fn drawIndexed(self: *RenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    self.vkd.cmdDrawIndexed(self.command_buffer, index_count, instance_count, first_index, base_vertex, first_instance);
}
