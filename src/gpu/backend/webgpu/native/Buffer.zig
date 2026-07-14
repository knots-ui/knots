const std = @import("std");
const wgpu = @import("wgpu");
const CommonBuffer = @import("gpu").Buffer;
const Desc = CommonBuffer.Desc;

const Buffer = @This();

allocator: std.mem.Allocator,
buffer: wgpu.Buffer,
queue: wgpu.Queue,
device: wgpu.Device,
size: usize,
usage: wgpu.Buffer.Usage,
label: []u8,

pub fn create(allocator: std.mem.Allocator, device: wgpu.Device, queue: wgpu.Queue, desc: Desc) !Buffer {
    try CommonBuffer.validateDesc(desc);
    const label = try allocator.dupe(u8, desc.label);
    errdefer allocator.free(label);
    const wgpu_usage = toWgpuUsage(CommonBuffer.effectiveUsage(desc));
    var out = Buffer{
        .allocator = allocator,
        .buffer = try device.createBuffer(.{
            .usage = wgpu_usage,
            .size = desc.size,
            .label = label,
        }),
        .queue = queue,
        .device = device,
        .size = desc.size,
        .usage = wgpu_usage,
        .label = label,
    };
    if (desc.initial_data) |data| if (data.len != 0) out.loadOffset(u8, data, 0);
    return out;
}

fn toWgpuUsage(usage: CommonBuffer.Usage) wgpu.Buffer.Usage {
    return .{
        .vertex = usage.vertex,
        .index = usage.index,
        .uniform = usage.uniform,
        .copy_dst = usage.copy_dst,
        .copy_src = usage.copy_src,
        .storage = usage.storage,
    };
}

pub fn deinit(self: *Buffer) void {
    self.buffer.deinit();
    self.allocator.free(self.label);
}

pub fn load(self: *Buffer, comptime T: type, data: []const T) void {
    self.loadOffset(T, data, 0);
}

pub fn loadOffset(self: *Buffer, comptime T: type, data: []const T, offset: usize) void {
    std.debug.assert(@sizeOf(T) != 0);
    const byte_len = data.len * @sizeOf(T);
    std.debug.assert(offset <= self.size and byte_len <= self.size - offset);
    const bytes: [*]const u8 = @ptrCast(data.ptr);
    self.queue.writeBuffer(u8, self.buffer, offset, bytes[0..byte_len]);
}

pub fn getSize(self: *const Buffer) usize {
    return self.size;
}

pub fn resize(self: *Buffer, new_size: usize) !void {
    std.debug.assert(new_size != 0);
    const new_buffer = try self.device.createBuffer(.{
        .usage = self.usage,
        .size = new_size,
        .label = self.label,
    });
    self.buffer.deinit();
    self.buffer = new_buffer;
    self.size = new_size;
}
