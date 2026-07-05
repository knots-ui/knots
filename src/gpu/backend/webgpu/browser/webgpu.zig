const js = @import("js-bridge");
const gpu = @import("gpu");

var pending_error: ?js.Error = null;

pub const buffer_usage = struct {
    pub const map_read: u32 = 1;
    pub const map_write: u32 = 2;
    pub const copy_src: u32 = 4;
    pub const copy_dst: u32 = 8;
    pub const index: u32 = 16;
    pub const vertex: u32 = 32;
    pub const uniform: u32 = 64;
    pub const storage: u32 = 128;
};

pub const texture_usage = struct {
    pub const copy_src: u32 = 1;
    pub const copy_dst: u32 = 2;
    pub const texture_binding: u32 = 4;
    pub const storage_binding: u32 = 8;
    pub const render_attachment: u32 = 16;
};

pub const shader_stage = struct {
    pub const vertex: u32 = 1;
    pub const fragment: u32 = 2;
};

pub const color_write_all: u32 = 15;

pub fn host() js.Error!js.Value {
    return js.host();
}

pub fn recordError(err: js.Error) void {
    if (pending_error == null) pending_error = err;
}

pub fn takeError() ?js.Error {
    const err = pending_error;
    pending_error = null;
    return err;
}

pub fn formatName(format: gpu.Texture.Format) []const u8 {
    return switch (format) {
        .rgba8 => "rgba8unorm",
        .rgba8_srgb => "rgba8unorm-srgb",
        .bgra8 => "bgra8unorm",
        .bgra8_srgb => "bgra8unorm-srgb",
        .r8 => "r8unorm",
        .rgba32f => "rgba32float",
        .rgba32u => "rgba32uint",
    };
}

pub fn preferredFormat(value: js.Value) gpu.Texture.Format {
    if (value.eqlString("rgba8unorm")) return .rgba8;
    if (value.eqlString("rgba8unorm-srgb")) return .rgba8_srgb;
    if (value.eqlString("bgra8unorm")) return .bgra8;
    if (value.eqlString("bgra8unorm-srgb")) return .bgra8_srgb;
    return .bgra8;
}

pub fn isSrgb(format: gpu.Texture.Format) bool {
    return switch (format) {
        .rgba8_srgb, .bgra8_srgb => true,
        else => false,
    };
}

pub fn bufferUsageBits(usage: gpu.Buffer.Usage) u32 {
    var bits: u32 = 0;
    if (usage.vertex) bits |= buffer_usage.vertex;
    if (usage.index) bits |= buffer_usage.index;
    if (usage.uniform) bits |= buffer_usage.uniform;
    if (usage.copy_dst) bits |= buffer_usage.copy_dst;
    if (usage.copy_src) bits |= buffer_usage.copy_src;
    if (usage.storage) bits |= buffer_usage.storage;
    return bits;
}

pub fn textureUsageBits(usage: gpu.Texture.Usage) u32 {
    var bits: u32 = 0;
    if (usage.texture_binding) bits |= texture_usage.texture_binding;
    if (usage.copy_dst) bits |= texture_usage.copy_dst;
    if (usage.copy_src) bits |= texture_usage.copy_src;
    if (usage.render_attachment) bits |= texture_usage.render_attachment;
    return bits;
}

pub fn shaderVisibilityBits(flags: gpu.Pipeline.ShaderStageFlags) u32 {
    var bits: u32 = 0;
    if (flags.vertex) bits |= shader_stage.vertex;
    if (flags.fragment) bits |= shader_stage.fragment;
    return bits;
}

pub fn vertexFormatName(format: gpu.Pipeline.VertexFormat) []const u8 {
    return switch (format) {
        .f32 => "float32",
        .f32x2 => "float32x2",
        .f32x3 => "float32x3",
        .f32x4 => "float32x4",
    };
}

pub fn stepModeName(mode: gpu.Pipeline.VertexStepMode) []const u8 {
    return switch (mode) {
        .vertex => "vertex",
        .instance => "instance",
    };
}

pub fn filterName(mode: gpu.Sampler.FilterMode) []const u8 {
    return switch (mode) {
        .nearest => "nearest",
        .linear => "linear",
    };
}

pub fn addressModeName(mode: gpu.Sampler.AddressMode) []const u8 {
    return switch (mode) {
        .clamp_to_edge => "clamp-to-edge",
        .repeat => "repeat",
        .mirror_repeat => "mirror-repeat",
    };
}

pub fn blendFactorName(factor: gpu.Pipeline.BlendFactor) []const u8 {
    return switch (factor) {
        .zero => "zero",
        .one => "one",
        .src_alpha => "src-alpha",
        .one_minus_src_alpha => "one-minus-src-alpha",
    };
}

pub fn blendOpName(op: gpu.Pipeline.BlendOp) []const u8 {
    return switch (op) {
        .add => "add",
    };
}

pub fn extent3d(width: u32, height: u32, depth: u32) js.Error!js.Value {
    var out = try js.ObjectBuilder.init();
    try out.set("width", js.Arg.u32(width));
    try out.set("height", js.Arg.u32(height));
    try out.set("depthOrArrayLayers", js.Arg.u32(depth));
    return out.finish();
}

pub fn origin3d(x: u32, y: u32, z: u32) js.Error!js.Value {
    var out = try js.ObjectBuilder.init();
    try out.set("x", js.Arg.u32(x));
    try out.set("y", js.Arg.u32(y));
    try out.set("z", js.Arg.u32(z));
    return out.finish();
}

pub fn setLabel(builder: *const js.ObjectBuilder, label: []const u8) js.Error!void {
    if (label.len > 0) try builder.set("label", js.Arg.string(label));
}
