const Texture = @import("Texture.zig");

pub const ShaderSource = union(enum) {
    wgsl: []const u8,
    spirv: struct {
        vs: []align(@alignOf(u32)) const u8,
        fs: []align(@alignOf(u32)) const u8,
        vs_entry: []const u8 = "main",
        fs_entry: []const u8 = "main",
    },
};

pub const VertexStepMode = enum { vertex, instance };

pub const VertexFormat = enum { f32, f32x2, f32x3, f32x4, u32, f16x4 };

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

pub const CompareFunction = enum {
    always,
    less,
    less_equal,
};

pub const DepthStencilState = struct {
    format: Texture.Format,
    depth_write_enabled: bool,
    depth_compare: CompareFunction,
};

pub const CullMode = enum {
    none,
    back,
};

pub const FrontFace = enum {
    ccw,
    cw,
};

pub const PrimitiveState = struct {
    cull_mode: CullMode = .none,
    front_face: FrontFace = .ccw,
};

pub const Desc = struct {
    label: []const u8 = "",
    shader: ShaderSource,
    vs_entry: []const u8 = "vs_main",
    fs_entry: []const u8 = "fs_main",
    vertex_buffers: []const VertexBufferLayout,
    bind_group_layouts: []const BindGroupLayoutDesc,
    color_target: ColorTargetState,
    depth_stencil: ?DepthStencilState = null,
    primitive: PrimitiveState = .{},
};

/// Fields named with a leading `_` are padding and get no attribute.
pub fn attrsFromStruct(comptime T: type) [attributeCount(T)]VertexAttribute {
    const field_names = @typeInfo(T).@"struct".field_names;
    const field_types = @typeInfo(T).@"struct".field_types;
    var attrs: [attributeCount(T)]VertexAttribute = undefined;
    comptime var i = 0;
    inline for (field_names, field_types) |field_name, field_type| {
        if (comptime field_name[0] == '_') continue;
        defer i += 1;
        attrs[i] = .{
            .location = i,
            .offset = @offsetOf(T, field_name),
            .format = switch (@typeInfo(field_type)) {
                .array => |arr| switch (arr.child) {
                    f32 => switch (arr.len) {
                        2 => .f32x2,
                        3 => .f32x3,
                        4 => .f32x4,
                        else => @compileError("unsupported array length for vertex attribute"),
                    },
                    f16 => switch (arr.len) {
                        4 => .f16x4,
                        else => @compileError("unsupported array length for vertex attribute"),
                    },
                    else => @compileError("unsupported array element type for vertex attribute"),
                },
                .float => |float| switch (float.bits) {
                    32 => .f32,
                    else => @compileError("unsupported float width for vertex attribute"),
                },
                .int => |int| switch (int.bits) {
                    32 => .u32,
                    else => @compileError("unsupported integer width for vertex attribute"),
                },
                else => @compileError("unsupported field type for vertex attribute"),
            },
        };
    }
    return attrs;
}

fn attributeCount(comptime T: type) usize {
    var count = 0;
    for (@typeInfo(T).@"struct".field_names) |name| {
        if (name[0] != '_') count += 1;
    }
    return count;
}
