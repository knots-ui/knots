const gpu = @import("gpu");
const shaders = @import("shaders.zig");

pub const SlugUniforms = extern struct {
    mvp_row0: [4]f32,
    mvp_row1: [4]f32,
    mvp_row2: [4]f32,
    mvp_row3: [4]f32,
    viewport: [4]f32,
};

pub const ViewportUniform = [2]f32;

pub const PrimitivesKind = enum { vertex, instance };

const standard_blend = gpu.Pipeline.BlendState{
    .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha, .op = .add },
    .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha, .op = .add },
};

const premultiplied_blend = gpu.Pipeline.BlendState{
    .color = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha, .op = .add },
    .alpha = .{ .src_factor = .one, .dst_factor = .one_minus_src_alpha, .op = .add },
};

const vertex_attrs = gpu.Pipeline.attrsFromStruct(gpu.Vertex);
const instance_attrs = gpu.Pipeline.attrsFromStruct(gpu.Instance);
const slug_attrs = gpu.Pipeline.attrsFromStruct(gpu.SlugVertex);

const vertex_buffers = [_]gpu.Pipeline.VertexBufferLayout{.{
    .stride = @sizeOf(gpu.Vertex),
    .step_mode = .vertex,
    .attributes = &vertex_attrs,
}};

const instance_buffers = [_]gpu.Pipeline.VertexBufferLayout{.{
    .stride = @sizeOf(gpu.Instance),
    .step_mode = .instance,
    .attributes = &instance_attrs,
}};

const slug_buffers = [_]gpu.Pipeline.VertexBufferLayout{.{
    .stride = @sizeOf(gpu.SlugVertex),
    .step_mode = .vertex,
    .attributes = &slug_attrs,
}};

const primitives_uniform_bgl = gpu.Pipeline.BindGroupLayoutDesc{
    .label = "primitives_uniform_bgl",
    .entries = &.{
        .{ .binding = 0, .visibility = .{ .vertex = true }, .type = .uniform_buffer },
    },
};

const primitives_texture_bgl = gpu.Pipeline.BindGroupLayoutDesc{
    .label = "primitives_texture_bgl",
    .entries = &.{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .type = .{ .sampled_texture = .float } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .type = .{ .sampler = .filtering } },
    },
};

const clip_bgl = gpu.Pipeline.BindGroupLayoutDesc{
    .label = "clip_bgl",
    .entries = &.{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .type = .read_only_storage_buffer },
    },
};

const primitives_bgls = [_]gpu.Pipeline.BindGroupLayoutDesc{ primitives_uniform_bgl, primitives_texture_bgl, clip_bgl };

const slug_uniform_bgl = gpu.Pipeline.BindGroupLayoutDesc{
    .label = "slug_uniform_bgl",
    .entries = &.{
        .{ .binding = 0, .visibility = .{ .vertex = true, .fragment = true }, .type = .uniform_buffer },
    },
};

const slug_curveband_bgl = gpu.Pipeline.BindGroupLayoutDesc{
    .label = "slug_curveband_bgl",
    .entries = &.{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .type = .{ .sampled_texture = .unfilterable_float } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .type = .{ .sampled_texture = .uint } },
    },
};

const slug_bgls = [_]gpu.Pipeline.BindGroupLayoutDesc{ slug_uniform_bgl, slug_curveband_bgl, clip_bgl };

pub fn primitivesDesc(kind: PrimitivesKind, srgb_surface: bool) gpu.Pipeline.Desc {
    return primitivesDescForTarget(kind, null, !srgb_surface);
}

pub fn linearTargetPrimitivesDesc(kind: PrimitivesKind) gpu.Pipeline.Desc {
    return primitivesDescForTarget(kind, .rgba8, false);
}

fn primitivesDescForTarget(kind: PrimitivesKind, target_format: ?gpu.Texture.Format, encode_srgb: bool) gpu.Pipeline.Desc {
    const vbs: []const gpu.Pipeline.VertexBufferLayout = switch (kind) {
        .vertex => &vertex_buffers,
        .instance => &instance_buffers,
    };
    const vs_entry: []const u8 = switch (kind) {
        .vertex => "vs_main",
        .instance => "vs_instance_main",
    };
    const fs_entry: []const u8 = if (encode_srgb) "fs_main_srgb_encode" else "fs_main";

    const shader: gpu.Pipeline.ShaderSource = switch (gpu.Backend) {
        .webgpu => .{ .wgsl = shaders.primitives_wgsl },
        .vulkan => .{ .spirv = .{
            .vs = switch (kind) {
                .vertex => shaders.primitives_vert_spv,
                .instance => shaders.primitives_instance_vert_spv,
            },
            .fs = shaders.primitives_frag_spv,
            .fs_entry = fs_entry,
        } },
    };

    return .{
        .label = "primitives",
        .shader = shader,
        .vs_entry = vs_entry,
        .fs_entry = fs_entry,
        .vertex_buffers = vbs,
        .bind_group_layouts = &primitives_bgls,
        .color_target = .{ .format = target_format, .blend = standard_blend },
    };
}

pub fn slugDesc(srgb_surface: bool) gpu.Pipeline.Desc {
    return slugDescForTarget(null, !srgb_surface);
}

pub fn linearTargetSlugDesc() gpu.Pipeline.Desc {
    return slugDescForTarget(.rgba8, false);
}

fn slugDescForTarget(target_format: ?gpu.Texture.Format, encode_srgb: bool) gpu.Pipeline.Desc {
    const fs_entry: []const u8 = if (encode_srgb) "fs_main_srgb_encode" else "fs_main";

    const shader: gpu.Pipeline.ShaderSource = switch (gpu.Backend) {
        .webgpu => .{ .wgsl = shaders.slug_wgsl },
        .vulkan => .{ .spirv = .{ .vs = shaders.slug_vert_spv, .fs = shaders.slug_frag_spv, .fs_entry = fs_entry } },
    };

    return .{
        .label = "slug",
        .shader = shader,
        .vs_entry = "vs_main",
        .fs_entry = fs_entry,
        .vertex_buffers = &slug_buffers,
        .bind_group_layouts = &slug_bgls,
        .color_target = .{ .format = target_format, .blend = premultiplied_blend },
    };
}

pub fn computeSlugUniforms(width: f32, height: f32, physical_width: f32, physical_height: f32, y_down_clip: bool) SlugUniforms {
    // y_down_clip = Vulkan (clip y goes down). wgpu has y-up, so flip y.
    const y_sign: f32 = if (y_down_clip) 1.0 else -1.0;
    const y_offset: f32 = if (y_down_clip) -1.0 else 1.0;
    return .{
        .mvp_row0 = .{ 2.0 / width, 0, 0, -1 },
        .mvp_row1 = .{ 0, y_sign * 2.0 / height, 0, y_offset },
        .mvp_row2 = .{ 0, 0, 1, 0 },
        .mvp_row3 = .{ 0, 0, 0, 1 },
        .viewport = .{ width, height, physical_width, physical_height },
    };
}
