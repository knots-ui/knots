const std = @import("std");
const vk = @import("vk");
const CommonBuffer = @import("gpu").Buffer;
const Device = @import("Device.zig");
const MemoryAllocator = @import("MemoryAllocator.zig");

const Buffer = @This();

device: *Device,
buffer: vk.Buffer,
allocation: MemoryAllocator.Allocation,
mapped: ?[*]u8,
size: usize,
usage: vk.BufferUsageFlags,
label: []u8,

const Allocation = struct {
    buffer: vk.Buffer,
    allocation: MemoryAllocator.Allocation,
    mapped: ?[*]u8,
};

fn allocate(device: *Device, size: usize, usage: vk.BufferUsageFlags, device_local: bool) !Allocation {
    std.debug.assert(size != 0);
    std.debug.assert(usage.toInt() != 0);
    const buffer = try device.vkd.createBuffer(device.device, &.{
        .size = @intCast(size),
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer device.vkd.destroyBuffer(device.device, buffer, null);

    var dedicated = vk.MemoryDedicatedRequirements{
        .prefers_dedicated_allocation = undefined,
        .requires_dedicated_allocation = undefined,
    };
    var requirements = vk.MemoryRequirements2{ .p_next = &dedicated, .memory_requirements = undefined };
    device.vkd.getBufferMemoryRequirements2(device.device, &.{ .buffer = buffer }, &requirements);
    const allocation = try device.memory_allocator.allocate(
        requirements.memory_requirements,
        dedicated,
        .{ .buffer = buffer },
        .linear,
        if (device_local) .{ .device_local = true } else .{ .host_visible = true, .host_coherent = true },
        if (device_local) .{ .host_visible = true, .host_coherent = true } else .{ .device_local = true },
    );
    errdefer device.memory_allocator.free(allocation);
    try device.vkd.bindBufferMemory(device.device, buffer, allocation.memory, allocation.offset);
    if (!device_local) std.debug.assert(allocation.mapped != null);
    return .{
        .buffer = buffer,
        .allocation = allocation,
        .mapped = if (allocation.properties.host_coherent) allocation.mapped else null,
    };
}

pub fn create(device: *Device, desc: CommonBuffer.Desc) !Buffer {
    try CommonBuffer.validateDesc(desc);
    const label = try device.allocator.dupe(u8, desc.label);
    errdefer device.allocator.free(label);
    const vk_usage = toVkUsage(CommonBuffer.effectiveUsage(desc));
    const a = try allocate(device, desc.size, vk_usage, desc.initial_data != null);
    errdefer {
        device.vkd.destroyBuffer(device.device, a.buffer, null);
        device.memory_allocator.free(a.allocation);
    }
    device.setDebugName(.buffer, @backingInt(a.buffer), label);

    var out = Buffer{
        .device = device,
        .buffer = a.buffer,
        .allocation = a.allocation,
        .mapped = a.mapped,
        .size = desc.size,
        .usage = vk_usage,
        .label = label,
    };
    if (desc.initial_data) |data| {
        if (data.len > 0) {
            if (out.mapped != null) {
                out.loadOffset(u8, data, 0);
            } else {
                try uploadInitialData(device, out.buffer, data);
            }
        }
    }
    return out;
}

fn toVkUsage(usage: CommonBuffer.Usage) vk.BufferUsageFlags {
    return vk.BufferUsageFlags{
        .vertex_buffer = usage.vertex,
        .index_buffer = usage.index,
        .uniform_buffer = usage.uniform,
        .transfer_dst = usage.copy_dst,
        .transfer_src = usage.copy_src,
        .storage_buffer = usage.storage,
    };
}

pub fn deinit(self: *Buffer) void {
    self.device.vkd.destroyBuffer(self.device.device, self.buffer, null);
    self.device.memory_allocator.free(self.allocation);
    self.device.allocator.free(self.label);
}

pub fn load(self: *Buffer, comptime T: type, data: []const T) void {
    self.loadOffset(T, data, 0);
}

pub fn loadOffset(self: *Buffer, comptime T: type, data: []const T, offset: usize) void {
    std.debug.assert(@sizeOf(T) != 0);
    std.debug.assert(self.mapped != null);
    const byte_len = data.len * @sizeOf(T);
    std.debug.assert(offset <= self.size and byte_len <= self.size - offset);
    const bytes: [*]const u8 = @ptrCast(data.ptr);
    @memcpy(self.mapped.?[offset .. offset + byte_len], bytes[0..byte_len]);
}

pub fn getSize(self: *const Buffer) usize {
    return self.size;
}

pub fn resize(self: *Buffer, new_size: usize) !void {
    std.debug.assert(new_size != 0);
    std.debug.assert(self.mapped != null);
    const a = try allocate(self.device, new_size, self.usage, false);
    self.device.setDebugName(.buffer, @backingInt(a.buffer), self.label);

    self.device.vkd.destroyBuffer(self.device.device, self.buffer, null);
    self.device.memory_allocator.free(self.allocation);

    self.buffer = a.buffer;
    self.allocation = a.allocation;
    self.mapped = a.mapped;
    self.size = new_size;
}

fn uploadInitialData(device: *Device, target: vk.Buffer, data: []const u8) !void {
    std.debug.assert(data.len > 0);
    std.debug.assert(data.len % 4 == 0);
    const staging = try allocate(device, data.len, .{ .transfer_src = true }, false);
    defer device.memory_allocator.free(staging.allocation);
    defer device.vkd.destroyBuffer(device.device, staging.buffer, null);
    @memcpy(staging.mapped.?[0..data.len], data);

    const pool = try device.vkd.createCommandPool(device.device, &.{
        .queue_family_index = device.queue_family,
        .flags = .{ .transient = true },
    }, null);
    defer device.vkd.destroyCommandPool(device.device, pool, null);
    var commands: [1]vk.CommandBuffer = undefined;
    try device.vkd.allocateCommandBuffers(device.device, &.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, &commands);
    const command = commands[0];
    const fence = try device.vkd.createFence(device.device, &.{ .flags = .{} }, null);
    defer device.vkd.destroyFence(device.device, fence, null);
    try device.vkd.beginCommandBuffer(command, &.{ .flags = .{ .one_time_submit = true } });
    device.vkd.cmdCopyBuffer(command, staging.buffer, target, &.{.{
        .src_offset = 0,
        .dst_offset = 0,
        .size = data.len,
    }});
    device.vkd.cmdPipelineBarrier2(command, &.{
        .memory_barrier_count = 1,
        .p_memory_barriers = &[_]vk.MemoryBarrier2{.{
            .src_stage_mask = .{ .copy = true },
            .src_access_mask = .{ .transfer_write = true },
            .dst_stage_mask = .{ .all_commands = true },
            .dst_access_mask = .{ .memory_read = true },
        }},
    });
    try device.vkd.endCommandBuffer(command);
    {
        device.lockQueue();
        defer device.unlockQueue();
        try device.vkd.queueSubmit2(device.graphics_queue, &.{.{
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = &[_]vk.CommandBufferSubmitInfo{.{ .command_buffer = command, .device_mask = 1 }},
        }}, fence);
    }
    // Persistent buffer creation is synchronous; staging must outlive the copy.
    _ = try device.vkd.waitForFences(device.device, &.{fence}, .true, std.math.maxInt(u64));
}
