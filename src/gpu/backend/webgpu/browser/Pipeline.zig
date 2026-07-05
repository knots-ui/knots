const std = @import("std");
const js = @import("js-bridge");
const CommonPipeline = @import("gpu").Pipeline;
const TextureFormat = @import("gpu").Texture.Format;
const webgpu = @import("webgpu.zig");

const Device = @import("Device.zig");

const Pipeline = @This();

allocator: std.mem.Allocator,
render_pipeline: js.Value,
bind_group_layouts: []js.Value,

pub fn create(allocator: std.mem.Allocator, device: *Device, desc: CommonPipeline.Desc) !Pipeline {
    const wgsl = switch (desc.shader) {
        .wgsl => |s| s,
        .spirv => return error.UnsupportedShaderSource,
    };

    var shader_desc = try js.ObjectBuilder.init();
    defer shader_desc.finish().release();
    try shader_desc.set("code", js.Arg.string(wgsl));
    const shader_module = try device.device.call("createShaderModule", &.{js.Arg.value(shader_desc.value)});
    defer shader_module.release();

    const bgls = try allocator.alloc(js.Value, desc.bind_group_layouts.len);
    errdefer allocator.free(bgls);
    var bgls_created: usize = 0;
    errdefer for (bgls[0..bgls_created]) |bgl| bgl.release();

    for (desc.bind_group_layouts, 0..) |bgl_desc, i| {
        bgls[i] = try createBindGroupLayout(device.device, bgl_desc);
        bgls_created += 1;
    }

    const bgl_array = try js.newArray();
    defer bgl_array.release();
    for (bgls) |bgl| try bgl_array.push(js.Arg.value(bgl));

    var layout_desc = try js.ObjectBuilder.init();
    defer layout_desc.finish().release();
    try webgpu.setLabel(&layout_desc, desc.label);
    try layout_desc.set("bindGroupLayouts", js.Arg.value(bgl_array));
    const pipeline_layout = try device.device.call("createPipelineLayout", &.{js.Arg.value(layout_desc.value)});
    defer pipeline_layout.release();

    const vertex = try createVertexState(shader_module, desc);
    defer vertex.release();
    const fragment = try createFragmentState(shader_module, device.surface_format, desc);
    defer fragment.release();

    var pipeline_desc = try js.ObjectBuilder.init();
    defer pipeline_desc.finish().release();
    try webgpu.setLabel(&pipeline_desc, desc.label);
    try pipeline_desc.set("layout", js.Arg.value(pipeline_layout));
    try pipeline_desc.set("vertex", js.Arg.value(vertex));
    try pipeline_desc.set("fragment", js.Arg.value(fragment));

    const render_pipeline = try device.device.call("createRenderPipeline", &.{js.Arg.value(pipeline_desc.value)});
    return .{
        .allocator = allocator,
        .render_pipeline = render_pipeline,
        .bind_group_layouts = bgls,
    };
}

pub fn deinit(self: *Pipeline) void {
    self.render_pipeline.release();
    for (self.bind_group_layouts) |bgl| bgl.release();
    self.allocator.free(self.bind_group_layouts);
}

pub fn bindGroupLayout(self: *const Pipeline, index: u32) js.Value {
    return self.bind_group_layouts[index];
}

fn createBindGroupLayout(device: js.Value, desc: CommonPipeline.BindGroupLayoutDesc) !js.Value {
    const entries = try js.newArray();
    defer entries.release();
    for (desc.entries) |entry| {
        const js_entry = try bindGroupLayoutEntry(entry);
        defer js_entry.release();
        try entries.push(js.Arg.value(js_entry));
    }

    var js_desc = try js.ObjectBuilder.init();
    defer js_desc.finish().release();
    try webgpu.setLabel(&js_desc, desc.label);
    try js_desc.set("entries", js.Arg.value(entries));
    return device.call("createBindGroupLayout", &.{js.Arg.value(js_desc.value)});
}

fn bindGroupLayoutEntry(entry: CommonPipeline.BindGroupLayoutEntry) !js.Value {
    var out = try js.ObjectBuilder.init();
    try out.set("binding", js.Arg.u32(entry.binding));
    try out.set("visibility", js.Arg.u32(webgpu.shaderVisibilityBits(entry.visibility)));

    switch (entry.type) {
        .uniform_buffer => {
            const buffer = try bufferBindingLayout("uniform");
            defer buffer.release();
            try out.set("buffer", js.Arg.value(buffer));
        },
        .read_only_storage_buffer => {
            const buffer = try bufferBindingLayout("read-only-storage");
            defer buffer.release();
            try out.set("buffer", js.Arg.value(buffer));
        },
        .sampled_texture => |sample_type| {
            const texture = try textureBindingLayout(sample_type);
            defer texture.release();
            try out.set("texture", js.Arg.value(texture));
        },
        .sampler => |binding_type| {
            const sampler = try samplerBindingLayout(binding_type);
            defer sampler.release();
            try out.set("sampler", js.Arg.value(sampler));
        },
    }

    return out.finish();
}

fn bufferBindingLayout(binding_type: []const u8) !js.Value {
    var out = try js.ObjectBuilder.init();
    try out.set("type", js.Arg.string(binding_type));
    return out.finish();
}

fn textureBindingLayout(sample_type: CommonPipeline.TextureSampleType) !js.Value {
    var out = try js.ObjectBuilder.init();
    try out.set("sampleType", js.Arg.string(switch (sample_type) {
        .float => "float",
        .unfilterable_float => "unfilterable-float",
        .uint => "uint",
    }));
    try out.set("viewDimension", js.Arg.string("2d"));
    return out.finish();
}

fn samplerBindingLayout(binding_type: CommonPipeline.SamplerBindingType) !js.Value {
    var out = try js.ObjectBuilder.init();
    try out.set("type", js.Arg.string(switch (binding_type) {
        .filtering => "filtering",
        .non_filtering => "non-filtering",
    }));
    return out.finish();
}

fn createVertexState(shader_module: js.Value, desc: CommonPipeline.Desc) !js.Value {
    const buffers = try js.newArray();
    defer buffers.release();

    for (desc.vertex_buffers) |vb| {
        const attrs = try js.newArray();
        defer attrs.release();
        for (vb.attributes) |attr| {
            var js_attr = try js.ObjectBuilder.init();
            defer js_attr.finish().release();
            try js_attr.set("shaderLocation", js.Arg.u32(attr.location));
            try js_attr.set("offset", js.Arg.u32(attr.offset));
            try js_attr.set("format", js.Arg.string(webgpu.vertexFormatName(attr.format)));
            try attrs.push(js.Arg.value(js_attr.value));
        }

        var js_vb = try js.ObjectBuilder.init();
        defer js_vb.finish().release();
        try js_vb.set("arrayStride", js.Arg.u32(vb.stride));
        try js_vb.set("stepMode", js.Arg.string(webgpu.stepModeName(vb.step_mode)));
        try js_vb.set("attributes", js.Arg.value(attrs));
        try buffers.push(js.Arg.value(js_vb.value));
    }

    var out = try js.ObjectBuilder.init();
    try out.set("module", js.Arg.value(shader_module));
    try out.set("entryPoint", js.Arg.string(desc.vs_entry));
    try out.set("buffers", js.Arg.value(buffers));
    return out.finish();
}

fn createFragmentState(shader_module: js.Value, surface_format: TextureFormat, desc: CommonPipeline.Desc) !js.Value {
    const targets = try js.newArray();
    defer targets.release();

    var target = try js.ObjectBuilder.init();
    defer target.finish().release();
    const format = desc.color_target.format orelse surface_format;
    try target.set("format", js.Arg.string(webgpu.formatName(format)));
    try target.set("writeMask", js.Arg.u32(webgpu.color_write_all));

    if (desc.color_target.blend) |blend| {
        const js_blend = try blendState(blend);
        defer js_blend.release();
        try target.set("blend", js.Arg.value(js_blend));
    }
    try targets.push(js.Arg.value(target.value));

    var out = try js.ObjectBuilder.init();
    try out.set("module", js.Arg.value(shader_module));
    try out.set("entryPoint", js.Arg.string(desc.fs_entry));
    try out.set("targets", js.Arg.value(targets));
    return out.finish();
}

fn blendState(blend: CommonPipeline.BlendState) !js.Value {
    var out = try js.ObjectBuilder.init();
    const color = try blendComponent(blend.color);
    defer color.release();
    const alpha = try blendComponent(blend.alpha);
    defer alpha.release();
    try out.set("color", js.Arg.value(color));
    try out.set("alpha", js.Arg.value(alpha));
    return out.finish();
}

fn blendComponent(component: CommonPipeline.BlendComponent) !js.Value {
    var out = try js.ObjectBuilder.init();
    try out.set("operation", js.Arg.string(webgpu.blendOpName(component.op)));
    try out.set("srcFactor", js.Arg.string(webgpu.blendFactorName(component.src_factor)));
    try out.set("dstFactor", js.Arg.string(webgpu.blendFactorName(component.dst_factor)));
    return out.finish();
}
