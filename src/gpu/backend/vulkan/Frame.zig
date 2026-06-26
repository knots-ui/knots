const std = @import("std");
const vk = @import("vk");
const gpu = @import("gpu");
const GpuContext = @import("Context.zig");
const RenderPass = @import("RenderPass.zig");
const Buffer = @import("Buffer.zig");

const FrameData = struct {
    command_buffer: vk.CommandBuffer,
    image_available: vk.Semaphore,
    render_finished: vk.Semaphore,
    in_flight: vk.Fence,
};

const Frame = @This();

allocator: std.mem.Allocator,
ctx: *GpuContext,
frames: []FrameData,
current: u32,
image_index: u32,

pub const ContextHandle = struct {
    frame: *Frame,
    upload_slot: u32,

    pub fn beginRenderPass(self: *ContextHandle, desc: RenderPass.Desc) !RenderPass {
        return self.frame.beginRenderPass(desc);
    }

    pub fn submit(self: *ContextHandle) !void {
        try self.frame.submit();
    }

    pub fn submitReadback(self: *ContextHandle, allocator: std.mem.Allocator) !gpu.SurfaceReadback {
        return self.frame.submitReadback(allocator);
    }
};

pub const Context = ContextHandle;

pub fn create(allocator: std.mem.Allocator, ctx: *GpuContext) !Frame {
    const frame_count = ctx.swapchain_images.len;
    const frames = try allocator.alloc(FrameData, frame_count);
    var created: usize = 0;

    errdefer {
        for (frames[0..created], ctx.command_pools[0..created]) |f, pool| {
            ctx.vkd.freeCommandBuffers(ctx.device, pool, &.{f.command_buffer});
            ctx.vkd.destroySemaphore(ctx.device, f.image_available, null);
            ctx.vkd.destroySemaphore(ctx.device, f.render_finished, null);
            ctx.vkd.destroyFence(ctx.device, f.in_flight, null);
        }
        allocator.free(frames);
    }

    for (frames, ctx.command_pools) |*f, pool| {
        var cmd: [1]vk.CommandBuffer = undefined;
        var committed = false;
        var command_buffer_allocated = false;
        var image_available: vk.Semaphore = .null_handle;
        var render_finished: vk.Semaphore = .null_handle;
        var in_flight: vk.Fence = .null_handle;

        errdefer if (!committed) {
            if (command_buffer_allocated) ctx.vkd.freeCommandBuffers(ctx.device, pool, &.{cmd[0]});
            if (image_available != .null_handle) ctx.vkd.destroySemaphore(ctx.device, image_available, null);
            if (render_finished != .null_handle) ctx.vkd.destroySemaphore(ctx.device, render_finished, null);
            if (in_flight != .null_handle) ctx.vkd.destroyFence(ctx.device, in_flight, null);
        };

        try ctx.vkd.allocateCommandBuffers(ctx.device, &.{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, &cmd);
        command_buffer_allocated = true;
        image_available = try ctx.vkd.createSemaphore(ctx.device, &.{}, null);
        render_finished = try ctx.vkd.createSemaphore(ctx.device, &.{}, null);
        in_flight = try ctx.vkd.createFence(ctx.device, &.{ .flags = .{ .signaled_bit = true } }, null);

        f.* = .{
            .command_buffer = cmd[0],
            .image_available = image_available,
            .render_finished = render_finished,
            .in_flight = in_flight,
        };
        committed = true;
        created += 1;
    }

    return .{
        .allocator = allocator,
        .ctx = ctx,
        .frames = frames,
        .current = 0,
        .image_index = 0,
    };
}

pub fn deinit(self: *Frame) void {
    const ctx = self.ctx;
    ctx.vkd.deviceWaitIdle(ctx.device) catch {};
    for (self.frames, ctx.command_pools) |f, pool| {
        ctx.vkd.freeCommandBuffers(ctx.device, pool, &.{f.command_buffer});
        ctx.vkd.destroySemaphore(ctx.device, f.image_available, null);
        ctx.vkd.destroySemaphore(ctx.device, f.render_finished, null);
        ctx.vkd.destroyFence(ctx.device, f.in_flight, null);
    }
    self.allocator.free(self.frames);
}

pub fn begin(self: *Frame) !ContextHandle {
    const f = &self.frames[self.current];
    _ = try self.ctx.vkd.waitForFences(self.ctx.device, &.{f.in_flight}, .true, std.math.maxInt(u64));
    return .{ .frame = self, .upload_slot = self.current };
}

pub fn uploadSlotCount(self: *const Frame) u32 {
    return @intCast(self.frames.len);
}

pub fn prepareResize(_: *Frame) void {}

fn acquireImage(ctx: *GpuContext, semaphore: vk.Semaphore) !u32 {
    const result = try ctx.vkd.acquireNextImageKHR(ctx.device, ctx.swapchain, std.math.maxInt(u64), semaphore, .null_handle);
    return result.image_index;
}

fn beginRenderPass(self: *Frame, desc: RenderPass.Desc) !RenderPass {
    const ctx = self.ctx;
    const f = &self.frames[self.current];

    const image_index = acquireImage(ctx, f.image_available) catch |err| blk: {
        if (err != error.OutOfDateKHR) return err;
        try ctx.vkd.deviceWaitIdle(ctx.device);
        try ctx.recreateSwapchain(ctx.swapchain_extent.width, ctx.swapchain_extent.height);
        break :blk try acquireImage(ctx, f.image_available);
    };

    try ctx.vkd.resetFences(ctx.device, &.{f.in_flight});

    self.image_index = image_index;

    try ctx.vkd.resetCommandPool(ctx.device, ctx.command_pools[self.current], .{});
    try ctx.vkd.beginCommandBuffer(f.command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

    return RenderPass.create(f.command_buffer, ctx, image_index, desc);
}

fn submit(self: *Frame) !void {
    try self.submitCommands();
    try self.present();
}

fn submitCommands(self: *Frame) !void {
    const ctx = self.ctx;
    const f = &self.frames[self.current];

    try ctx.vkd.endCommandBuffer(f.command_buffer);

    try ctx.vkd.queueSubmit2(ctx.graphics_queue, &.{.{
        .wait_semaphore_info_count = 1,
        .p_wait_semaphore_infos = &[_]vk.SemaphoreSubmitInfo{.{
            .semaphore = f.image_available,
            .value = 0,
            .stage_mask = .{ .color_attachment_output_bit = true },
            .device_index = 0,
        }},
        .command_buffer_info_count = 1,
        .p_command_buffer_infos = &[_]vk.CommandBufferSubmitInfo{.{
            .command_buffer = f.command_buffer,
            .device_mask = 1,
        }},
        .signal_semaphore_info_count = 1,
        .p_signal_semaphore_infos = &[_]vk.SemaphoreSubmitInfo{.{
            .semaphore = f.render_finished,
            .value = 0,
            .stage_mask = .{ .all_commands_bit = true },
            .device_index = 0,
        }},
    }}, f.in_flight);
}

fn present(self: *Frame) !void {
    const ctx = self.ctx;
    const f = &self.frames[self.current];
    const present_result: ?vk.Result = ctx.vkd.queuePresentKHR(ctx.graphics_queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &[_]vk.Semaphore{f.render_finished},
        .swapchain_count = 1,
        .p_swapchains = &[_]vk.SwapchainKHR{ctx.swapchain},
        .p_image_indices = &[_]u32{self.image_index},
    }) catch |err|
        switch (err) {
            error.OutOfDateKHR => out_of_date: {
                try ctx.vkd.deviceWaitIdle(ctx.device);
                ctx.recreateSwapchain(ctx.swapchain_extent.width, ctx.swapchain_extent.height) catch |err2| switch (err2) {
                    error.SurfaceUnavailable => break :out_of_date null,
                    else => return err2,
                };
                break :out_of_date null;
            },
            else => return err,
        };

    if (present_result) |result| {
        if (result == .suboptimal_khr) {
            try ctx.vkd.deviceWaitIdle(ctx.device);
            try ctx.recreateSwapchain(ctx.swapchain_extent.width, ctx.swapchain_extent.height);
        }
    }

    self.current = (self.current + 1) % @as(u32, @intCast(self.frames.len));
}

fn submitReadback(self: *Frame, allocator: std.mem.Allocator) !gpu.SurfaceReadback {
    const ctx = self.ctx;
    if (!ctx.swapchain_copy_src) return error.SurfaceReadbackUnsupported;

    const width = ctx.swapchain_extent.width;
    const height = ctx.swapchain_extent.height;
    const format = ctx.surfaceFormat();
    const row_bytes = try readbackRowBytes(width, format);
    const readback_size = try readbackByteSize(width, height, format);
    var readback = try Buffer.create(ctx.allocator, ctx, readback_size, .{ .copy_dst = true });
    defer readback.deinit();

    const submitted_frame = self.current;
    const command_buffer = self.frames[submitted_frame].command_buffer;
    ctx.vkd.cmdPipelineBarrier2(command_buffer, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[_]vk.ImageMemoryBarrier2{.{
            .src_stage_mask = .{ .color_attachment_output_bit = true },
            .src_access_mask = .{ .color_attachment_write_bit = true },
            .dst_stage_mask = .{ .all_transfer_bit = true },
            .dst_access_mask = .{ .transfer_read_bit = true },
            .old_layout = .present_src_khr,
            .new_layout = .transfer_src_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = ctx.swapchain_images[self.image_index],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }},
    });
    ctx.vkd.cmdCopyImageToBuffer(
        command_buffer,
        ctx.swapchain_images[self.image_index],
        .transfer_src_optimal,
        readback.buffer,
        &.{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = width, .height = height, .depth = 1 },
        }},
    );
    ctx.vkd.cmdPipelineBarrier2(command_buffer, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[_]vk.ImageMemoryBarrier2{.{
            .src_stage_mask = .{ .all_transfer_bit = true },
            .src_access_mask = .{ .transfer_read_bit = true },
            .dst_stage_mask = .{},
            .dst_access_mask = .{},
            .old_layout = .transfer_src_optimal,
            .new_layout = .present_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = ctx.swapchain_images[self.image_index],
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }},
    });

    try self.submitCommands();
    const in_flight = self.frames[submitted_frame].in_flight;
    _ = try ctx.vkd.waitForFences(ctx.device, &.{in_flight}, .true, std.math.maxInt(u64));
    try self.present();

    return .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .format = format,
        .bytes_per_row = row_bytes,
        .bytes = try allocator.dupe(u8, readback.mapped[0..readback_size]),
    };
}

fn readbackByteSize(width: u32, height: u32, format: gpu.Texture.Format) !usize {
    return std.math.mul(usize, try readbackRowBytes(width, format), @as(usize, height)) catch error.SurfaceReadbackTooLarge;
}

fn readbackRowBytes(width: u32, format: gpu.Texture.Format) !usize {
    return std.math.mul(usize, @as(usize, width), gpu.SurfaceReadback.bytesPerPixel(format)) catch error.SurfaceReadbackTooLarge;
}

pub fn waitForCompletion(self: *Frame) !void {
    const ctx = self.ctx;
    for (self.frames) |f| {
        _ = try ctx.vkd.waitForFences(ctx.device, &.{f.in_flight}, .true, std.math.maxInt(u64));
    }
}
