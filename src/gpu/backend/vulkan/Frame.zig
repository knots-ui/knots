const std = @import("std");
const vk = @import("vk");
const GpuContext = @import("Context.zig");
const RenderPass = @import("RenderPass.zig");

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
        return self.frame.submit();
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
    ctx._current_image_index = image_index;

    try ctx.vkd.resetCommandPool(ctx.device, ctx.command_pools[self.current], .{});
    try ctx.vkd.beginCommandBuffer(f.command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } });

    return RenderPass.create(self.allocator, f.command_buffer, ctx, desc);
}

fn submit(self: *Frame) !void {
    const ctx = self.ctx;
    const f = &self.frames[self.current];

    try ctx.vkd.endCommandBuffer(f.command_buffer);

    const wait_stage = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
    try ctx.vkd.queueSubmit(ctx.graphics_queue, &.{.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &[_]vk.Semaphore{f.image_available},
        .p_wait_dst_stage_mask = @ptrCast(&wait_stage),
        .command_buffer_count = 1,
        .p_command_buffers = &[_]vk.CommandBuffer{f.command_buffer},
        .signal_semaphore_count = 1,
        .p_signal_semaphores = &[_]vk.Semaphore{f.render_finished},
    }}, f.in_flight);

    const present_result = ctx.vkd.queuePresentKHR(ctx.graphics_queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &[_]vk.Semaphore{f.render_finished},
        .swapchain_count = 1,
        .p_swapchains = &[_]vk.SwapchainKHR{ctx.swapchain},
        .p_image_indices = &[_]u32{self.image_index},
    }) catch |err|
        switch (err) {
            error.OutOfDateKHR => {
                try ctx.vkd.deviceWaitIdle(ctx.device);
                try ctx.recreateSwapchain(ctx.swapchain_extent.width, ctx.swapchain_extent.height);
                self.current = (self.current + 1) % @as(u32, @intCast(self.frames.len));
                return;
            },
            else => return err,
        };

    if (present_result == .suboptimal_khr) {
        try ctx.vkd.deviceWaitIdle(ctx.device);
        try ctx.recreateSwapchain(ctx.swapchain_extent.width, ctx.swapchain_extent.height);
    }

    self.current = (self.current + 1) % @as(u32, @intCast(self.frames.len));
}

pub fn waitForCompletion(self: *Frame) !void {
    const ctx = self.ctx;
    for (self.frames) |f| {
        _ = try ctx.vkd.waitForFences(ctx.device, &.{f.in_flight}, .true, std.math.maxInt(u64));
    }
}
