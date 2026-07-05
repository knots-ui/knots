const js = @import("js-bridge");
const Device = @import("Device.zig");
const Pipeline = @import("Pipeline.zig");
const Buffer = @import("Buffer.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const BindGroup = @This();

bind_group: js.Value,

pub const BufferBinding = struct {
    buffer: *const Buffer,
    offset: u64 = 0,
    size: u64 = 0,
};

pub const Entry = union(enum) {
    buffer: BufferBinding,
    read_only_storage_buffer: BufferBinding,
    texture_view: *const Texture,
    sampler: *const Sampler,
};

pub const BindingEntry = struct {
    binding: u32,
    resource: Entry,
};

pub const Desc = struct {
    label: []const u8 = "",
    pipeline: *const Pipeline,
    layout_index: u32,
    entries: []const BindingEntry,
};

pub fn create(device: *Device, desc: Desc) !BindGroup {
    const entries = try js.newArray();
    defer entries.release();
    for (desc.entries) |entry| {
        const js_entry = try bindGroupEntry(entry);
        defer js_entry.release();
        try entries.push(js.Arg.value(js_entry));
    }

    var js_desc = try js.ObjectBuilder.init();
    defer js_desc.finish().release();
    if (desc.label.len > 0) try js_desc.set("label", js.Arg.string(desc.label));
    try js_desc.set("layout", js.Arg.value(desc.pipeline.bindGroupLayout(desc.layout_index)));
    try js_desc.set("entries", js.Arg.value(entries));

    return .{ .bind_group = try device.device.call("createBindGroup", &.{js.Arg.value(js_desc.value)}) };
}

pub fn deinit(self: *BindGroup) void {
    self.bind_group.release();
}

fn bindGroupEntry(entry: BindingEntry) !js.Value {
    var out = try js.ObjectBuilder.init();
    try out.set("binding", js.Arg.u32(entry.binding));

    const resource = switch (entry.resource) {
        .buffer => |binding| try bufferBinding(binding),
        .read_only_storage_buffer => |binding| try bufferBinding(binding),
        .texture_view => |texture| texture.view.retain(),
        .sampler => |sampler| sampler.sampler.retain(),
    };
    defer resource.release();
    try out.set("resource", js.Arg.value(resource));
    return out.finish();
}

fn bufferBinding(binding: BufferBinding) !js.Value {
    var out = try js.ObjectBuilder.init();
    try out.set("buffer", js.Arg.value(binding.buffer.buffer));
    try out.set("offset", js.Arg.usize(@intCast(binding.offset)));
    const size: usize = if (binding.size == 0)
        binding.buffer.size - @as(usize, @intCast(binding.offset))
    else
        @intCast(binding.size);
    try out.set("size", js.Arg.usize(size));
    return out.finish();
}
