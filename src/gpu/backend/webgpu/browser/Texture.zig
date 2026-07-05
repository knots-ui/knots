const js = @import("js-bridge");
const CommonTexture = @import("gpu").Texture;
const webgpu = @import("webgpu.zig");

pub const NativeHandle = struct {
    texture: js.Value,
    view: js.Value,
    format: CommonTexture.Format,
    width: u32,
    height: u32,
};

const Texture = @This();

const Format = CommonTexture.Format;
const Desc = CommonTexture.Desc;

texture: js.Value,
view: js.Value,
queue: js.Value,
width: u32,
height: u32,
format: Format,
ready: bool,
native_handle: NativeHandle,

pub fn create(device: js.Value, queue: js.Value, desc: Desc) !Texture {
    var js_desc = try js.ObjectBuilder.init();
    defer js_desc.finish().release();
    try webgpu.setLabel(&js_desc, desc.label);

    const size = try webgpu.extent3d(desc.width, desc.height, 1);
    defer size.release();
    try js_desc.set("size", js.Arg.value(size));
    try js_desc.set("format", js.Arg.string(webgpu.formatName(desc.format)));
    try js_desc.set("usage", js.Arg.u32(webgpu.textureUsageBits(desc.usage)));
    try js_desc.set("mipLevelCount", js.Arg.u32(1));
    try js_desc.set("sampleCount", js.Arg.u32(1));
    try js_desc.set("dimension", js.Arg.string("2d"));

    const texture = try device.call("createTexture", &.{js.Arg.value(js_desc.value)});
    errdefer texture.release();

    var view_desc = try js.ObjectBuilder.init();
    defer view_desc.finish().release();
    try view_desc.set("format", js.Arg.string(webgpu.formatName(desc.format)));
    const view = try texture.call("createView", &.{js.Arg.value(view_desc.value)});

    return .{
        .texture = texture,
        .view = view,
        .queue = queue.retain(),
        .width = desc.width,
        .height = desc.height,
        .format = desc.format,
        .ready = false,
        .native_handle = .{
            .texture = texture.retain(),
            .view = view.retain(),
            .format = desc.format,
            .width = desc.width,
            .height = desc.height,
        },
    };
}

pub fn deinit(self: *Texture) void {
    self.native_handle.view.release();
    self.native_handle.texture.release();
    self.view.release();
    self.texture.callVoid("destroy", &.{}) catch {};
    self.texture.release();
    self.queue.release();
}

pub fn write(self: *Texture, data: [*]const u8, len: usize, x: u32, y: u32, width: u32, height: u32, bytes_per_row: ?u32) !void {
    var dest = try js.ObjectBuilder.init();
    defer dest.finish().release();
    try dest.set("texture", js.Arg.value(self.texture));
    try dest.set("mipLevel", js.Arg.u32(0));
    const origin = try webgpu.origin3d(x, y, 0);
    defer origin.release();
    try dest.set("origin", js.Arg.value(origin));

    var layout = try js.ObjectBuilder.init();
    defer layout.finish().release();
    try layout.set("offset", js.Arg.u32(0));
    try layout.set("bytesPerRow", js.Arg.u32(bytes_per_row orelse width * bytesPerPixel(self.format)));
    try layout.set("rowsPerImage", js.Arg.u32(height));

    const size = try webgpu.extent3d(width, height, 1);
    defer size.release();

    try self.queue.callVoid("writeTexture", &.{
        js.Arg.value(dest.value),
        js.Arg.bytes(data[0..len]),
        js.Arg.value(layout.value),
        js.Arg.value(size),
    });
    self.ready = true;
}

pub fn isReady(self: *const Texture) bool {
    return self.ready;
}

pub fn nativeHandle(self: *Texture) *anyopaque {
    self.native_handle.view.release();
    self.native_handle.texture.release();
    self.native_handle = .{
        .texture = self.texture.retain(),
        .view = self.view.retain(),
        .format = self.format,
        .width = self.width,
        .height = self.height,
    };
    return &self.native_handle;
}

fn bytesPerPixel(format: Format) u32 {
    return switch (format) {
        .rgba8, .rgba8_srgb, .bgra8, .bgra8_srgb => 4,
        .r8 => 1,
        .rgba32f, .rgba32u => 16,
    };
}
