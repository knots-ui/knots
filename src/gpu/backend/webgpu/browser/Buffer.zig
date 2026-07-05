const js = @import("js-bridge");
const webgpu = @import("webgpu.zig");
const Usage = @import("gpu").Buffer.Usage;

const Buffer = @This();

buffer: js.Value,
queue: js.Value,
device: js.Value,
size: usize,
usage: Usage,

pub fn create(device: js.Value, queue: js.Value, size: usize, usage: Usage) !Buffer {
    const buffer = try createRawBuffer(device, size, usage);
    return .{
        .buffer = buffer,
        .queue = queue.retain(),
        .device = device.retain(),
        .size = size,
        .usage = usage,
    };
}

pub fn deinit(self: *Buffer) void {
    self.buffer.callVoid("destroy", &.{}) catch {};
    self.buffer.release();
    self.queue.release();
    self.device.release();
}

pub fn load(self: *Buffer, comptime T: type, data: []const T) void {
    const bytes: [*]const u8 = @ptrCast(data.ptr);
    self.queue.callVoid("writeBuffer", &.{
        js.Arg.value(self.buffer),
        js.Arg.u32(0),
        js.Arg.bytes(bytes[0 .. data.len * @sizeOf(T)]),
    }) catch |err| webgpu.recordError(err);
}

pub fn getSize(self: *const Buffer) usize {
    return self.size;
}

pub fn resize(self: *Buffer, new_size: usize) !void {
    const new_buffer = try createRawBuffer(self.device, new_size, self.usage);
    self.buffer.callVoid("destroy", &.{}) catch {};
    self.buffer.release();
    self.buffer = new_buffer;
    self.size = new_size;
}

fn createRawBuffer(device: js.Value, size: usize, usage: Usage) !js.Value {
    var desc = try js.ObjectBuilder.init();
    defer desc.finish().release();
    try desc.set("usage", js.Arg.u32(webgpu.bufferUsageBits(usage)));
    try desc.set("size", js.Arg.usize(size));
    return device.call("createBuffer", &.{js.Arg.value(desc.value)});
}
