const std = @import("std");
const vk = @import("vk");
const gpu = @import("gpu");
const Device = @import("Device.zig");
const Surface = @import("Surface.zig");
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
surface: *Surface,
frames: []FrameData,
command_pools: []vk.CommandPool,
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

pub fn create(surface: *Surface) !Frame {
    const allocator = surface.allocator;
    const device = surface.device;
    const frame_count = surface.swapchain_images.len;
    const command_pools = try createCommandPools(allocator, device, frame_count);
    errdefer destroyCommandPools(allocator, device, command_pools);

    const frames = try allocator.alloc(FrameData, frame_count);
    var created: usize = 0;

    errdefer {
        for (frames[0..created], command_pools[0..created]) |f, pool| {
            device.vkd.freeCommandBuffers(device.device, pool, &.{f.command_buffer});
            device.vkd.destroySemaphore(device.device, f.image_available, null);
            device.vkd.destroySemaphore(device.device, f.render_finished, null);
            device.vkd.destroyFence(device.device, f.in_flight, null);
        }
        allocator.free(frames);
    }

    for (frames, command_pools) |*f, pool| {
        var cmd: [1]vk.CommandBuffer = undefined;
        var committed = false;
        var command_buffer_allocated = false;
        var image_available: vk.Semaphore = .null_handle;
        var render_finished: vk.Semaphore = .null_handle;
        var in_flight: vk.Fence = .null_handle;

        errdefer if (!committed) {
            if (command_buffer_allocated) device.vkd.freeCommandBuffers(device.device, pool, &.{cmd[0]});
            if (image_available != .null_handle) device.vkd.destroySemaphore(device.device, image_available, null);
            if (render_finished != .null_handle) device.vkd.destroySemaphore(device.device, render_finished, null);
            if (in_flight != .null_handle) device.vkd.destroyFence(device.device, in_flight, null);
        };

        try device.vkd.allocateCommandBuffers(device.device, &.{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, &cmd);
        command_buffer_allocated = true;
        image_available = try device.vkd.createSemaphore(device.device, &.{}, null);
        render_finished = try device.vkd.createSemaphore(device.device, &.{}, null);
        in_flight = try device.vkd.createFence(device.device, &.{ .flags = .{ .signaled = true } }, null);

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
        .surface = surface,
        .frames = frames,
        .command_pools = command_pools,
        .current = 0,
        .image_index = 0,
    };
}

pub fn deinit(self: *Frame) void {
    const device = self.surface.device;
    waitForPresentQueue(device) catch {};
    for (self.frames, self.command_pools) |f, pool| {
        device.vkd.freeCommandBuffers(device.device, pool, &.{f.command_buffer});
        device.vkd.destroySemaphore(device.device, f.image_available, null);
        device.vkd.destroySemaphore(device.device, f.render_finished, null);
        device.vkd.destroyFence(device.device, f.in_flight, null);
    }
    self.allocator.free(self.frames);
    destroyCommandPools(self.allocator, device, self.command_pools);
}

pub fn begin(self: *Frame) !ContextHandle {
    const f = &self.frames[self.current];
    const device = self.surface.device;
    _ = try device.vkd.waitForFences(device.device, &.{f.in_flight}, .true, std.math.maxInt(u64));
    return .{ .frame = self, .upload_slot = self.current };
}

pub fn uploadSlotCount(self: *const Frame) u32 {
    return @intCast(self.frames.len);
}

pub fn prepareResize(self: *Frame) void {
    waitForPresentQueue(self.surface.device) catch {};
}

fn acquireImage(device: *Device, surface: *Surface, semaphore: vk.Semaphore) !u32 {
    const result = try device.vkd.acquireNextImageKHR(device.device, surface.swapchain, std.math.maxInt(u64), semaphore, .null_handle);
    return result.image_index;
}

fn beginRenderPass(self: *Frame, desc: RenderPass.Desc) !RenderPass {
    const surface = self.surface;
    const device = surface.device;
    const f = &self.frames[self.current];

    const image_index = acquireImage(device, surface, f.image_available) catch |err| blk: {
        if (err != error.OutOfDateKHR) return err;
        try waitForPresentQueue(device);
        try surface.recreateSwapchain(surface.swapchain_extent.width, surface.swapchain_extent.height);
        break :blk try acquireImage(device, surface, f.image_available);
    };

    try device.vkd.resetFences(device.device, &.{f.in_flight});

    self.image_index = image_index;

    try device.vkd.resetCommandPool(device.device, self.command_pools[self.current], .{});
    try device.vkd.beginCommandBuffer(f.command_buffer, &.{ .flags = .{ .one_time_submit = true } });

    return RenderPass.create(f.command_buffer, device, surface, image_index, desc);
}

fn submit(self: *Frame) !void {
    try self.submitCommands();
    try self.present();
}

fn submitCommands(self: *Frame) !void {
    const device = self.surface.device;
    const f = &self.frames[self.current];

    try device.vkd.endCommandBuffer(f.command_buffer);

    try device.vkd.queueSubmit2(device.graphics_queue, &.{.{
        .wait_semaphore_info_count = 1,
        .p_wait_semaphore_infos = &[_]vk.SemaphoreSubmitInfo{.{
            .semaphore = f.image_available,
            .value = 0,
            .stage_mask = .{ .color_attachment_output = true },
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
            .stage_mask = .{ .all_commands = true },
            .device_index = 0,
        }},
    }}, f.in_flight);
}

fn present(self: *Frame) !void {
    const surface = self.surface;
    const device = surface.device;
    const f = &self.frames[self.current];
    const present_result: ?vk.Result = device.vkd.queuePresentKHR(device.graphics_queue, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &[_]vk.Semaphore{f.render_finished},
        .swapchain_count = 1,
        .p_swapchains = &[_]vk.SwapchainKHR{surface.swapchain},
        .p_image_indices = &[_]u32{self.image_index},
    }) catch |err|
        switch (err) {
            error.OutOfDateKHR => out_of_date: {
                try waitForPresentQueue(device);
                surface.recreateSwapchain(surface.swapchain_extent.width, surface.swapchain_extent.height) catch |err2| switch (err2) {
                    error.SurfaceUnavailable => break :out_of_date null,
                    else => return err2,
                };
                break :out_of_date null;
            },
            else => return err,
        };

    if (present_result) |result| {
        if (result == .suboptimal_khr) {
            try waitForPresentQueue(device);
            try surface.recreateSwapchain(surface.swapchain_extent.width, surface.swapchain_extent.height);
        }
    }

    self.current = (self.current + 1) % @as(u32, @intCast(self.frames.len));
}

fn submitReadback(self: *Frame, allocator: std.mem.Allocator) !gpu.SurfaceReadback {
    const surface = self.surface;
    const device = surface.device;
    if (!surface.swapchain_copy_src) return error.SurfaceReadbackUnsupported;

    const width = surface.swapchain_extent.width;
    const height = surface.swapchain_extent.height;
    const format = surface.getFormat();
    const row_bytes = try readbackRowBytes(width, format);
    const readback_size = try readbackByteSize(width, height, format);
    var readback = try Buffer.create(device, readback_size, .{ .copy_dst = true });
    defer readback.deinit();

    const submitted_frame = self.current;
    const command_buffer = self.frames[submitted_frame].command_buffer;
    device.vkd.cmdPipelineBarrier2(command_buffer, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[_]vk.ImageMemoryBarrier2{.{
            .src_stage_mask = .{ .color_attachment_output = true },
            .src_access_mask = .{ .color_attachment_write = true },
            .dst_stage_mask = .{ .all_transfer = true },
            .dst_access_mask = .{ .transfer_read = true },
            .old_layout = .present_src_khr,
            .new_layout = .transfer_src_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = surface.swapchain_images[self.image_index],
            .subresource_range = .{
                .aspect_mask = .{ .color = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }},
    });
    device.vkd.cmdCopyImageToBuffer(
        command_buffer,
        surface.swapchain_images[self.image_index],
        .transfer_src_optimal,
        readback.buffer,
        &.{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{
                .aspect_mask = .{ .color = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = width, .height = height, .depth = 1 },
        }},
    );
    device.vkd.cmdPipelineBarrier2(command_buffer, &.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = &[_]vk.ImageMemoryBarrier2{.{
            .src_stage_mask = .{ .all_transfer = true },
            .src_access_mask = .{ .transfer_read = true },
            .dst_stage_mask = .{},
            .dst_access_mask = .{},
            .old_layout = .transfer_src_optimal,
            .new_layout = .present_src_khr,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = surface.swapchain_images[self.image_index],
            .subresource_range = .{
                .aspect_mask = .{ .color = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }},
    });

    try self.submitCommands();
    const in_flight = self.frames[submitted_frame].in_flight;
    _ = try device.vkd.waitForFences(device.device, &.{in_flight}, .true, std.math.maxInt(u64));
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
    const device = self.surface.device;
    for (self.frames) |f| {
        _ = try device.vkd.waitForFences(device.device, &.{f.in_flight}, .true, std.math.maxInt(u64));
    }
}

fn waitForPresentQueue(device: *Device) !void {
    try device.vkd.queueWaitIdle(device.graphics_queue);
}

fn createCommandPools(allocator: std.mem.Allocator, device: *Device, count: usize) ![]vk.CommandPool {
    const command_pools = try allocator.alloc(vk.CommandPool, count);
    var pools_created: usize = 0;
    errdefer {
        for (command_pools[0..pools_created]) |pool| device.vkd.destroyCommandPool(device.device, pool, null);
        allocator.free(command_pools);
    }

    for (command_pools) |*pool| {
        pool.* = try device.vkd.createCommandPool(device.device, &.{
            .queue_family_index = device.queue_family,
            .flags = .{ .reset_command_buffer = true },
        }, null);
        pools_created += 1;
    }
    return command_pools;
}

fn destroyCommandPools(allocator: std.mem.Allocator, device: *Device, command_pools: []vk.CommandPool) void {
    for (command_pools) |pool| device.vkd.destroyCommandPool(device.device, pool, null);
    allocator.free(command_pools);
}
