const vk = @import("vk");
const Usage = @import("gpu").Buffer.Usage;
const Device = @import("Device.zig");

const Buffer = @This();

device: *Device,
buffer: vk.Buffer,
memory: vk.DeviceMemory,
mapped: [*]u8,
size: usize,
usage: vk.BufferUsageFlags,

const Allocation = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    mapped: [*]u8,
};

fn allocate(device: *Device, size: usize, usage: vk.BufferUsageFlags) !Allocation {
    const buffer = try device.vkd.createBuffer(device.device, &.{
        .size = @intCast(size),
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer device.vkd.destroyBuffer(device.device, buffer, null);

    const mem_reqs = device.vkd.getBufferMemoryRequirements(device.device, buffer);
    const mem_type = try device.findMemoryType(mem_reqs.memory_type_bits, .{ .host_visible = true, .host_coherent = true });

    const memory = try device.vkd.allocateMemory(device.device, &.{
        .allocation_size = mem_reqs.size,
        .memory_type_index = mem_type,
    }, null);
    errdefer device.vkd.freeMemory(device.device, memory, null);

    try device.vkd.bindBufferMemory(device.device, buffer, memory, 0);

    const mapped = try device.vkd.mapMemory(device.device, memory, 0, @intCast(size), .{});
    return .{ .buffer = buffer, .memory = memory, .mapped = @ptrCast(mapped) };
}

pub fn create(device: *Device, size: usize, usage: Usage) !Buffer {
    const vk_usage = toVkUsage(usage);
    const a = try allocate(device, size, vk_usage);
    errdefer {
        device.vkd.unmapMemory(device.device, a.memory);
        device.vkd.destroyBuffer(device.device, a.buffer, null);
        device.vkd.freeMemory(device.device, a.memory, null);
    }

    return .{
        .device = device,
        .buffer = a.buffer,
        .memory = a.memory,
        .mapped = a.mapped,
        .size = size,
        .usage = vk_usage,
    };
}

fn toVkUsage(usage: Usage) vk.BufferUsageFlags {
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
    self.device.vkd.unmapMemory(self.device.device, self.memory);
    self.device.vkd.destroyBuffer(self.device.device, self.buffer, null);
    self.device.vkd.freeMemory(self.device.device, self.memory, null);
}

pub fn load(self: *Buffer, comptime T: type, data: []const T) void {
    const bytes: [*]const u8 = @ptrCast(data.ptr);
    @memcpy(self.mapped[0 .. data.len * @sizeOf(T)], bytes[0 .. data.len * @sizeOf(T)]);
}

pub fn getSize(self: *const Buffer) usize {
    return self.size;
}

pub fn resize(self: *Buffer, new_size: usize) !void {
    const a = try allocate(self.device, new_size, self.usage);

    self.device.vkd.unmapMemory(self.device.device, self.memory);
    self.device.vkd.destroyBuffer(self.device.device, self.buffer, null);
    self.device.vkd.freeMemory(self.device.device, self.memory, null);

    self.buffer = a.buffer;
    self.memory = a.memory;
    self.mapped = a.mapped;
    self.size = new_size;
}
