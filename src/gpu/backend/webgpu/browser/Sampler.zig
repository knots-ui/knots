const js = @import("js-bridge");
const CommonSampler = @import("gpu").Sampler;
const webgpu = @import("webgpu.zig");

const Sampler = @This();

const Desc = CommonSampler.Desc;

sampler: js.Value,

pub fn create(device: js.Value, desc: Desc) !Sampler {
    var js_desc = try js.ObjectBuilder.init();
    defer js_desc.finish().release();
    try js_desc.set("magFilter", js.Arg.string(webgpu.filterName(desc.mag_filter)));
    try js_desc.set("minFilter", js.Arg.string(webgpu.filterName(desc.min_filter)));
    try js_desc.set("addressModeU", js.Arg.string(webgpu.addressModeName(desc.address_mode_u)));
    try js_desc.set("addressModeV", js.Arg.string(webgpu.addressModeName(desc.address_mode_v)));

    return .{ .sampler = try device.call("createSampler", &.{js.Arg.value(js_desc.value)}) };
}

pub fn deinit(self: *Sampler) void {
    self.sampler.release();
}
