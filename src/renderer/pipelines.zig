const gpu = @import("gpu");
const shaders = @import("render").shaders;

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
const slug_attrs = gpu.Pipeline.attrsFromStruct(gpu.SlugInstance);

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
    .stride = @sizeOf(gpu.SlugInstance),
    .step_mode = .instance,
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
        .webgpu => .{ .wgsl = shaders.text_wgsl },
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

/// Per-pass data for one Dual Kawase blur step, in source UV.
pub const BlurInstance = extern struct {
    /// xy = origin, zw = extent of the source region.
    source: [4]f32,
    /// Tap clamp: xy = min, zw = max.
    bounds: [4]f32,
    /// Tap distance; zero copies.
    tap: [2]f32,
};

/// One backdrop-filtered rounded rect, in logical pixels.
pub const GlassInstance = extern struct {
    rect: [4]f32,
    corner_radius: [4]f32,
    /// xy = logical origin of the filtered region, zw = its UV per logical pixel.
    sample_map: [4]f32,
    /// x = saturation, y = clip node.
    params: [4]f32,
    /// x = refraction, y = bezel, z = dispersion, w = specular.
    optics: [4]f32,
};

pub const BlurStep = enum { down, up };

const blur_attrs = gpu.Pipeline.attrsFromStruct(BlurInstance);
const glass_attrs = gpu.Pipeline.attrsFromStruct(GlassInstance);

const blur_buffers = [_]gpu.Pipeline.VertexBufferLayout{.{
    .stride = @sizeOf(BlurInstance),
    .step_mode = .instance,
    .attributes = &blur_attrs,
}};

const glass_buffers = [_]gpu.Pipeline.VertexBufferLayout{.{
    .stride = @sizeOf(GlassInstance),
    .step_mode = .instance,
    .attributes = &glass_attrs,
}};

// Identical to the primitives layouts, so their bind groups are interchangeable.
const blur_bgls = [_]gpu.Pipeline.BindGroupLayoutDesc{ primitives_uniform_bgl, primitives_texture_bgl };

/// Renders into a scene-format blur level; no blending and no depth.
pub fn blurDesc(step: BlurStep, target_format: ?gpu.Texture.Format) gpu.Pipeline.Desc {
    const fs_entry: []const u8 = switch (step) {
        .down => "fs_blur_down",
        .up => "fs_blur_up",
    };
    const shader: gpu.Pipeline.ShaderSource = switch (gpu.Backend) {
        .webgpu => .{ .wgsl = shaders.backdrop_wgsl },
        .vulkan => .{ .spirv = .{ .vs = shaders.backdrop_blur_vert_spv, .fs = shaders.backdrop_blur_frag_spv, .fs_entry = fs_entry } },
    };
    return .{
        .label = "backdrop_blur",
        .shader = shader,
        .vs_entry = "vs_blur",
        .fs_entry = fs_entry,
        .vertex_buffers = &blur_buffers,
        .bind_group_layouts = &blur_bgls,
        .color_target = .{ .format = target_format },
    };
}

/// Draws filtered backdrop into the scene target, which stores display encoding.
pub fn glassDesc(target_format: ?gpu.Texture.Format) gpu.Pipeline.Desc {
    const shader: gpu.Pipeline.ShaderSource = switch (gpu.Backend) {
        .webgpu => .{ .wgsl = shaders.backdrop_wgsl },
        .vulkan => .{ .spirv = .{ .vs = shaders.backdrop_glass_vert_spv, .fs = shaders.backdrop_glass_frag_spv, .fs_entry = "fs_glass" } },
    };
    return .{
        .label = "backdrop_glass",
        .shader = shader,
        .vs_entry = "vs_glass",
        .fs_entry = "fs_glass",
        .vertex_buffers = &glass_buffers,
        .bind_group_layouts = &primitives_bgls,
        .color_target = .{ .format = target_format, .blend = standard_blend },
    };
}
