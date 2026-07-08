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

pub const ClipNode = extern struct {
    rect: Vec4f,
    radii: Vec4f,
    parent: u32,
    pad0: u32,
    pad1: u32,
    pad2: u32,
};

pub const ClipNodes = extern struct {
    clip_nodes: @SpirvType(.{ .runtime_array = ClipNode }),
};

comptime {
    asm (
        \\OpDecorate %common_ClipNodes Block
    );
}

pub inline fn uniform(comptime T: type, name: []const u8, deco: ExternOptions.Decoration) *addrspace(.uniform) T {
    return _extern(T, .uniform, name, deco);
}

pub inline fn uniformConstant(comptime T: type, name: []const u8, deco: ExternOptions.Decoration) *addrspace(.constant) T {
    return _extern(T, .constant, name, deco);
}

pub inline fn storageBuffer(comptime T: type, name: []const u8, deco: ExternOptions.Decoration) *addrspace(.storage_buffer) const T {
    return @extern(*addrspace(.storage_buffer) const T, .{
        .name = name,
        .decoration = deco,
    });
}

pub inline fn input(comptime T: type, name: []const u8, deco: ExternOptions.Decoration) *addrspace(.input) T {
    return _extern(T, .input, name, deco);
}

pub inline fn output(comptime T: type, name: []const u8, deco: ExternOptions.Decoration) *addrspace(.output) T {
    return _extern(T, .output, name, deco);
}

inline fn _extern(comptime T: type, comptime addr_space: AddressSpace, name: []const u8, deco: ExternOptions.Decoration) *addrspace(addr_space) T {
    return @extern(*addrspace(addr_space) T, .{
        .name = name,
        .decoration = deco,
    });
}

pub inline fn sampleImplicitLod2Df(image: *addrspace(.constant) Image2D(f32), sampler: *addrspace(.constant) Sampler, coord: Vec2f) Vec4f {
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

pub inline fn texelFetch2Df(image: *addrspace(.constant) Image2D(f32), coord: Vec2i) Vec4f {
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

pub inline fn texelFetch2Du(image: *addrspace(.constant) Image2D(u32), coord: Vec2i) Vec4u {
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

pub inline fn fwidth2f(v: Vec2f) Vec2f {
    return asm (
        \\%float = OpTypeFloat 32
        \\%vec2 = OpTypeVector %float 2
        \\%ret = OpFwidth %vec2 %v
        : [ret] "=r" (-> Vec2f),
        : [v] "" (v),
    );
}

pub inline fn clamp(x: f32, lo: f32, hi: f32) f32 {
    return @min(@max(x, lo), hi);
}

pub inline fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

pub fn sdRoundedBox(p: Vec2f, half_size: Vec2f, radii: Vec4f) f32 {
    const radius = cornerRadius(p, normalizedRadii(radii, half_size * @as(Vec2f, @splat(2.0))));
    const q = absVec2f(p) - half_size + @as(Vec2f, @splat(radius));
    const outside = @max(q, @as(Vec2f, @splat(0.0)));
    const outside_len = @sqrt(outside[0] * outside[0] + outside[1] * outside[1]);
    return outside_len + @min(@max(q[0], q[1]), 0.0) - radius;
}

pub inline fn clipAlpha(clip_nodes: anytype, world_pos: Vec2f, clip_node: f32) f32 {
    var idx: u32 = @intFromFloat(clip_node + 0.5);
    var alpha: f32 = 1.0;
    var i: u32 = 0;
    while (i < 32 and idx != 0) : (i += 1) {
        const node = clip_nodes.*.clip_nodes[idx];
        const half_size: Vec2f = .{ node.rect[2] * 0.5, node.rect[3] * 0.5 };
        const center: Vec2f = .{ node.rect[0] + half_size[0], node.rect[1] + half_size[1] };
        const d = sdRoundedBox(world_pos - center, half_size, node.radii);
        alpha *= 1.0 - smoothstep(-0.5, 0.5, d);
        idx = node.parent;
    }
    return if (idx == 0) alpha else 0.0;
}

pub fn linearToSrgb(c: Vec3f) Vec3f {
    return .{ linearToSrgbChannel(c[0]), linearToSrgbChannel(c[1]), linearToSrgbChannel(c[2]) };
}

fn normalizedRadii(radii: Vec4f, size: Vec2f) Vec4f {
    var r = @max(radii, @as(Vec4f, @splat(0.0)));
    var scale: f32 = 1.0;
    if (r[0] + r[1] > size[0] and r[0] + r[1] > 0.0) scale = @min(scale, size[0] / (r[0] + r[1]));
    if (r[1] + r[2] > size[1] and r[1] + r[2] > 0.0) scale = @min(scale, size[1] / (r[1] + r[2]));
    if (r[2] + r[3] > size[0] and r[2] + r[3] > 0.0) scale = @min(scale, size[0] / (r[2] + r[3]));
    if (r[3] + r[0] > size[1] and r[3] + r[0] > 0.0) scale = @min(scale, size[1] / (r[3] + r[0]));
    r *= @as(Vec4f, @splat(scale));
    return r;
}

fn cornerRadius(p: Vec2f, radii: Vec4f) f32 {
    if (p[1] < 0.0) {
        return if (p[0] < 0.0) radii[0] else radii[1];
    }
    return if (p[0] >= 0.0) radii[2] else radii[3];
}

fn absVec2f(v: Vec2f) Vec2f {
    return .{ @abs(v[0]), @abs(v[1]) };
}

fn linearToSrgbChannel(c: f32) f32 {
    if (c <= 0.0031308) return 12.92 * c;
    return 1.055 * @exp(@log(c) * (1.0 / 2.4)) - 0.055;
}
