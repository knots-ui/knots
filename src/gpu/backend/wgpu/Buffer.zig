const std = @import("std");
const wgpu = @import("wgpu");
const Usage = @import("gpu").Buffer.Usage;

const Buffer = @This();

buffer: wgpu.Buffer,
queue: wgpu.Queue,
device: wgpu.Device,
size: usize,
usage: wgpu.Buffer.Usage,

pub fn create(_: std.mem.Allocator, device: wgpu.Device, queue: wgpu.Queue, size: usize, usage: Usage) !Buffer {
    const wgpu_usage = toWgpuUsage(usage);
    return .{
        .buffer = try device.createBuffer(.{
            .usage = wgpu_usage,
            .size = size,
            .label = "",
        }),
        .queue = queue,
        .device = device,
        .size = size,
        .usage = wgpu_usage,
    };
}

fn toWgpuUsage(usage: Usage) wgpu.Buffer.Usage {
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
}

pub fn load(self: *Buffer, comptime T: type, data: []const T) void {
    const bytes: [*]const u8 = @ptrCast(data.ptr);
    self.queue.writeBuffer(u8, self.buffer, 0, bytes[0 .. data.len * @sizeOf(T)]);
}

pub fn getSize(self: *const Buffer) usize {
    return self.size;
}

pub fn resize(self: *Buffer, new_size: usize) !void {
    const new_buffer = try self.device.createBuffer(.{
        .usage = self.usage,
        .size = new_size,
        .label = "",
    });
    self.buffer.deinit();
    self.buffer = new_buffer;
    self.size = new_size;
}
