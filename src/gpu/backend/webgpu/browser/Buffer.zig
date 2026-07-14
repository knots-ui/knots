const js = @import("js-bridge");
const std = @import("std");
const webgpu = @import("webgpu.zig");
const gpu = @import("gpu");

const Buffer = @This();

allocator: std.mem.Allocator,
buffer: js.Value,
queue: js.Value,
device: js.Value,
size: usize,
usage: gpu.Buffer.Usage,
label: []u8,

pub fn create(allocator: std.mem.Allocator, device: js.Value, queue: js.Value, desc: gpu.Buffer.Desc) !Buffer {
    try gpu.Buffer.validateDesc(desc);
    const label = try allocator.dupe(u8, desc.label);
    errdefer allocator.free(label);
    const usage = gpu.Buffer.effectiveUsage(desc);
    const buffer = try createRawBuffer(device, desc.size, usage, label);
    var out = Buffer{
        .allocator = allocator,
        .buffer = buffer,
        .queue = queue.retain(),
        .device = device.retain(),
        .size = desc.size,
        .usage = usage,
        .label = label,
    };
    if (desc.initial_data) |data| out.loadOffset(u8, data, 0);
    return out;
}

pub fn deinit(self: *Buffer) void {
    self.buffer.callVoid("destroy", &.{}) catch {};
    self.buffer.release();
    self.queue.release();
    self.device.release();
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
    self.queue.callVoid("writeBuffer", &.{
        js.Arg.value(self.buffer),
        js.Arg.usize(offset),
        js.Arg.bytes(bytes[0..byte_len]),
    }) catch |err| webgpu.recordError(err);
}

pub fn getSize(self: *const Buffer) usize {
    return self.size;
}

pub fn resize(self: *Buffer, new_size: usize) !void {
    std.debug.assert(new_size != 0);
    const new_buffer = try createRawBuffer(self.device, new_size, self.usage, self.label);
    self.buffer.callVoid("destroy", &.{}) catch {};
    self.buffer.release();
    self.buffer = new_buffer;
    self.size = new_size;
}

fn createRawBuffer(device: js.Value, size: usize, usage: gpu.Buffer.Usage, label: []const u8) !js.Value {
    var desc = try js.ObjectBuilder.init();
    defer desc.finish().release();
    try desc.set("usage", js.Arg.u32(webgpu.bufferUsageBits(usage)));
    try desc.set("size", js.Arg.usize(size));
    try desc.set("label", js.Arg.string(label));
    return device.call("createBuffer", &.{js.Arg.value(desc.value)});
}
