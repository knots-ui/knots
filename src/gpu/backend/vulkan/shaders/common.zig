const ExternOptions = @import("std").builtin.ExternOptions;
const AddressSpace = @import("std").builtin.AddressSpace;

pub const Vec4f = @Vector(4, f32);
pub const Vec2f = @Vector(2, f32);

pub inline fn uniform(comptime T: type, name: []const u8, deco: ExternOptions.Decoration) *addrspace(.uniform) T {
    return _extern(T, .uniform, name, deco);
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
