//! Helpers for writing SPIR-V shaders in Zig: vector types, image types, the
//! inputs, outputs and resources of a shader, and the GLSL-style operations Zig lacks.

const ExternOptions = @import("std").builtin.ExternOptions;
const AddressSpace = @import("std").builtin.AddressSpace;

pub const Vec4f = @Vector(4, f32);
pub const Vec3f = @Vector(3, f32);
pub const Vec2f = @Vector(2, f32);
pub const Vec4i = @Vector(4, i32);
pub const Vec2i = @Vector(2, i32);
pub const Vec4u = @Vector(4, u32);
pub const Vec2u = @Vector(2, u32);

pub const Sampler = @SpirvType(.sampler);

pub fn Image2D(comptime Sampled: type) type {
    return @SpirvType(.{ .image = .{
        .usage = .{ .sampled = Sampled },
        .format = .unknown,
        .dim = .@"2d",
        .depth = .not_depth,
        .access = .unknown,
        .arrayed = false,
        .multisampled = false,
    } });
}

pub fn uniform(comptime T: type, name: []const u8, deco: ExternOptions.Decoration) *addrspace(.uniform) T {
    return _extern(T, .uniform, name, deco);
}

pub fn uniformConstant(comptime T: type, name: []const u8, deco: ExternOptions.Decoration) *addrspace(.constant) T {
    return _extern(T, .constant, name, deco);
}

pub fn storageBuffer(comptime T: type, name: []const u8, deco: ExternOptions.Decoration) *addrspace(.storage_buffer) const T {
    return @extern(*addrspace(.storage_buffer) const T, .{
        .name = name,
        .decoration = deco,
    });
}

pub fn input(comptime T: type, name: []const u8, deco: ExternOptions.Decoration) *addrspace(.input) T {
    return _extern(T, .input, name, deco);
}

pub fn output(comptime T: type, name: []const u8, deco: ExternOptions.Decoration) *addrspace(.output) T {
    return _extern(T, .output, name, deco);
}

fn _extern(comptime T: type, comptime addr_space: AddressSpace, name: []const u8, deco: ExternOptions.Decoration) *addrspace(addr_space) T {
    return @extern(*addrspace(addr_space) T, .{
        .name = name,
        .decoration = deco,
    });
}

pub fn sampleImplicitLod2Df(image: *addrspace(.constant) Image2D(f32), sampler: *addrspace(.constant) Sampler, coord: Vec2f) Vec4f {
    return asm (
        \\%float = OpTypeFloat 32
        \\%v4float = OpTypeVector %float 4
        \\%img = OpTypeImage %float 2D 0 0 0 1 Unknown
        \\%smp = OpTypeSampler
        \\%sampled_img = OpTypeSampledImage %img
        \\%image_obj = OpLoad %img %image
        \\%sampler_obj = OpLoad %smp %sampler
        \\%combined = OpSampledImage %sampled_img %image_obj %sampler_obj
        \\%ret = OpImageSampleImplicitLod %v4float %combined %coord
        : [ret] "=r" (-> Vec4f),
        : [image] "" (image),
          [sampler] "" (sampler),
          [coord] "" (coord),
    );
}

pub fn texelFetch2Df(image: *addrspace(.constant) Image2D(f32), coord: Vec2i) Vec4f {
    return asm (
        \\%float = OpTypeFloat 32
        \\%uint = OpTypeInt 32 0
        \\%v4float = OpTypeVector %float 4
        \\%img = OpTypeImage %float 2D 0 0 0 1 Unknown
        \\%zero = OpConstant %uint 0
        \\%image_obj = OpLoad %img %image
        \\%ret = OpImageFetch %v4float %image_obj %coord Lod %zero
        : [ret] "=r" (-> Vec4f),
        : [image] "" (image),
          [coord] "" (coord),
    );
}

pub fn texelFetch2Du(image: *addrspace(.constant) Image2D(u32), coord: Vec2i) Vec4u {
    return asm (
        \\%uint = OpTypeInt 32 0
        \\%v4uint = OpTypeVector %uint 4
        \\%img = OpTypeImage %uint 2D 0 0 0 1 Unknown
        \\%zero = OpConstant %uint 0
        \\%image_obj = OpLoad %img %image
        \\%ret = OpImageFetch %v4uint %image_obj %coord Lod %zero
        : [ret] "=r" (-> Vec4u),
        : [image] "" (image),
          [coord] "" (coord),
    );
}

pub fn fwidth2f(v: Vec2f) Vec2f {
    return asm (
        \\%float = OpTypeFloat 32
        \\%vec2 = OpTypeVector %float 2
        \\%ret = OpFwidth %vec2 %v
        : [ret] "=r" (-> Vec2f),
        : [v] "" (v),
    );
}

pub fn clamp(x: f32, lo: f32, hi: f32) f32 {
    return @min(@max(x, lo), hi);
}

pub fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}
