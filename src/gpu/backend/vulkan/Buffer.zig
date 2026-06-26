const std = @import("std");
const vk = @import("vk");
const Usage = @import("gpu").Buffer.Usage;
const Context = @import("Context.zig");

const Buffer = @This();

ctx: *Context,
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

fn allocate(ctx: *Context, size: usize, usage: vk.BufferUsageFlags) !Allocation {
    const buffer = try ctx.vkd.createBuffer(ctx.device, &.{
        .size = @intCast(size),
        .usage = usage,
        .sharing_mode = .exclusive,
    }, null);
    errdefer ctx.vkd.destroyBuffer(ctx.device, buffer, null);

    const mem_reqs = ctx.vkd.getBufferMemoryRequirements(ctx.device, buffer);
    const mem_type = try ctx.findMemoryType(mem_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true });

    const memory = try ctx.vkd.allocateMemory(ctx.device, &.{
        .allocation_size = mem_reqs.size,
        .memory_type_index = mem_type,
    }, null);
    errdefer ctx.vkd.freeMemory(ctx.device, memory, null);

    try ctx.vkd.bindBufferMemory(ctx.device, buffer, memory, 0);

    const mapped = try ctx.vkd.mapMemory(ctx.device, memory, 0, @intCast(size), .{});
    return .{ .buffer = buffer, .memory = memory, .mapped = @ptrCast(mapped) };
}

pub fn create(_: std.mem.Allocator, ctx: *Context, size: usize, usage: Usage) !Buffer {
    const vk_usage = toVkUsage(usage);
    const a = try allocate(ctx, size, vk_usage);
    errdefer {
        ctx.vkd.unmapMemory(ctx.device, a.memory);
        ctx.vkd.destroyBuffer(ctx.device, a.buffer, null);
        ctx.vkd.freeMemory(ctx.device, a.memory, null);
    }

    return .{
        .ctx = ctx,
        .buffer = a.buffer,
        .memory = a.memory,
        .mapped = a.mapped,
        .size = size,
        .usage = vk_usage,
    };
}

fn toVkUsage(usage: Usage) vk.BufferUsageFlags {
    return vk.BufferUsageFlags{
        .vertex_buffer_bit = usage.vertex,
        .index_buffer_bit = usage.index,
        .uniform_buffer_bit = usage.uniform,
        .transfer_dst_bit = usage.copy_dst,
        .transfer_src_bit = usage.copy_src,
        .storage_buffer_bit = usage.storage,
    };
}

pub fn deinit(self: *Buffer) void {
    self.ctx.vkd.unmapMemory(self.ctx.device, self.memory);
    self.ctx.vkd.destroyBuffer(self.ctx.device, self.buffer, null);
    self.ctx.vkd.freeMemory(self.ctx.device, self.memory, null);
}

pub fn load(self: *Buffer, comptime T: type, data: []const T) void {
    const bytes: [*]const u8 = @ptrCast(data.ptr);
    @memcpy(self.mapped[0 .. data.len * @sizeOf(T)], bytes[0 .. data.len * @sizeOf(T)]);
}

pub fn getSize(self: *const Buffer) usize {
    return self.size;
}

pub fn resize(self: *Buffer, new_size: usize) !void {
    const a = try allocate(self.ctx, new_size, self.usage);

    self.ctx.vkd.unmapMemory(self.ctx.device, self.memory);
    self.ctx.vkd.destroyBuffer(self.ctx.device, self.buffer, null);
    self.ctx.vkd.freeMemory(self.ctx.device, self.memory, null);

    self.buffer = a.buffer;
    self.memory = a.memory;
    self.mapped = a.mapped;
    self.size = new_size;
}
