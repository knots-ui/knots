const Texture = @import("Texture.zig");

pub const ShaderSource = union(enum) {
    wgsl: []const u8,
    spirv: struct {
        vs: []align(@alignOf(u32)) const u8,
        fs: []align(@alignOf(u32)) const u8,
        vs_entry: []const u8 = "main",
        fs_entry: []const u8 = "main",
        srgb_encode_constant: ?u32 = null,
    },
};

pub const VertexStepMode = enum { vertex, instance };

pub const VertexFormat = enum { f32, f32x2, f32x3, f32x4 };

pub const VertexAttribute = struct {
    location: u32,
    offset: u32,
    format: VertexFormat,
};

pub const VertexBufferLayout = struct {
    stride: u32,
    step_mode: VertexStepMode,
    attributes: []const VertexAttribute,
};

pub const ShaderStageFlags = packed struct {
    vertex: bool = false,
    fragment: bool = false,
};

pub const TextureSampleType = enum { float, unfilterable_float, uint };
pub const SamplerBindingType = enum { filtering, non_filtering };

pub const BindingType = union(enum) {
    uniform_buffer,
    read_only_storage_buffer,
    sampled_texture: TextureSampleType,
    sampler: SamplerBindingType,
};

pub const BindGroupLayoutEntry = struct {
    binding: u32,
    visibility: ShaderStageFlags,
    type: BindingType,
};

pub const BindGroupLayoutDesc = struct {
    label: []const u8 = "",
    entries: []const BindGroupLayoutEntry,
};

pub const BlendFactor = enum { zero, one, src_alpha, one_minus_src_alpha };
pub const BlendOp = enum { add };

pub const BlendComponent = struct {
    src_factor: BlendFactor,
    dst_factor: BlendFactor,
    op: BlendOp = .add,
};

pub const BlendState = struct {
    color: BlendComponent,
    alpha: BlendComponent,
};

pub const ColorTargetState = struct {
    format: ?Texture.Format = null,
    blend: ?BlendState = null,
};

pub const Desc = struct {
    label: []const u8 = "",
    shader: ShaderSource,
    vs_entry: []const u8 = "vs_main",
    fs_entry: []const u8 = "fs_main",
    vertex_buffers: []const VertexBufferLayout,
    bind_group_layouts: []const BindGroupLayoutDesc,
    color_target: ColorTargetState,
};

pub fn attrsFromStruct(comptime T: type) [@typeInfo(T).@"struct".fields.len]VertexAttribute {
    const fields = @typeInfo(T).@"struct".fields;
    var attrs: [fields.len]VertexAttribute = undefined;
    inline for (fields, 0..) |field, i| {
        attrs[i] = .{
            .location = i,
            .offset = @offsetOf(T, field.name),
            .format = switch (@typeInfo(field.type)) {
                .array => |arr| switch (arr.child) {
                    f32 => switch (arr.len) {
                        2 => .f32x2,
                        3 => .f32x3,
                        4 => .f32x4,
                        else => @compileError("unsupported array length for vertex attribute"),
                    },
                    else => @compileError("unsupported array element type for vertex attribute"),
                },
                .float => |float| switch (float.bits) {
                    32 => .f32,
                    else => @compileError("unsupported float width for vertex attribute"),
                },
                else => @compileError("unsupported field type for vertex attribute"),
            },
        };
    }
    return attrs;
}
