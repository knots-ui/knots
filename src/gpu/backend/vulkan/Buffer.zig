const std = @import("std");
const vk = @import("vk");
const CommonBuffer = @import("gpu").Buffer;
const Device = @import("Device.zig");
const MemoryAllocator = @import("MemoryAllocator.zig");

const Buffer = @This();

device: *Device,
buffer: vk.Buffer,
allocation: MemoryAllocator.Allocation,
mapped: [*]u8,
size: usize,
usage: vk.BufferUsageFlags,
label: []u8,

const Allocation = struct {
    buffer: vk.Buffer,
    allocation: MemoryAllocator.Allocation,
    mapped: [*]u8,
};

fn allocate(device: *Device, size: usize, usage: vk.BufferUsageFlags) !Allocation {
    std.debug.assert(size != 0);
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
        .{ .host_visible = true, .host_coherent = true },
        .{ .device_local = true },
    );
    errdefer device.memory_allocator.free(allocation);
    try device.vkd.bindBufferMemory(device.device, buffer, allocation.memory, allocation.offset);
    std.debug.assert(allocation.mapped != null);
    return .{ .buffer = buffer, .allocation = allocation, .mapped = allocation.mapped.? };
}

pub fn create(device: *Device, desc: CommonBuffer.Desc) !Buffer {
    try CommonBuffer.validateDesc(desc);
    const label = try device.allocator.dupe(u8, desc.label);
    errdefer device.allocator.free(label);
    const vk_usage = toVkUsage(CommonBuffer.effectiveUsage(desc));
    const a = try allocate(device, desc.size, vk_usage);
    errdefer {
        device.vkd.destroyBuffer(device.device, a.buffer, null);
        device.memory_allocator.free(a.allocation);
    }
    device.setDebugName(.buffer, @intFromEnum(a.buffer), label);

    var out = Buffer{
        .device = device,
        .buffer = a.buffer,
        .allocation = a.allocation,
        .mapped = a.mapped,
        .size = desc.size,
        .usage = vk_usage,
        .label = label,
    };
    if (desc.initial_data) |data| if (data.len != 0) out.loadOffset(u8, data, 0);
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
    const byte_len = data.len * @sizeOf(T);
    std.debug.assert(offset <= self.size and byte_len <= self.size - offset);
    const bytes: [*]const u8 = @ptrCast(data.ptr);
    @memcpy(self.mapped[offset .. offset + byte_len], bytes[0..byte_len]);
}

pub fn getSize(self: *const Buffer) usize {
    return self.size;
}

pub fn resize(self: *Buffer, new_size: usize) !void {
    std.debug.assert(new_size != 0);
    const a = try allocate(self.device, new_size, self.usage);
    self.device.setDebugName(.buffer, @intFromEnum(a.buffer), self.label);

    self.device.vkd.destroyBuffer(self.device.device, self.buffer, null);
    self.device.memory_allocator.free(self.allocation);

    self.buffer = a.buffer;
    self.allocation = a.allocation;
    self.mapped = a.mapped;
    self.size = new_size;
}
