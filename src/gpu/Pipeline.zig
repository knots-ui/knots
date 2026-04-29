const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");

const Pipeline = @This();

pub const Kind = enum { vertex, instance, text };

pub const Desc = struct {
    kind: Kind = .vertex,
};

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    updateViewport: *const fn (ptr: *anyopaque, width: u32, height: u32) void,
    bindTexture: *const fn (ptr: *anyopaque, texture_ptr: *Texture, sampler_ptr: *Sampler) void,
    bindCurveBand: *const fn (ptr: *anyopaque, curve_tex: *Texture, band_tex: *Texture) void,
};

pub inline fn deinit(self: *const Pipeline) void {
    self.vtable.deinit(self.ptr);
}

pub inline fn updateViewport(self: *const Pipeline, width: u32, height: u32) void {
    self.vtable.updateViewport(self.ptr, width, height);
}

pub inline fn bindTexture(self: *const Pipeline, texture: *Texture, sampler: *Sampler) void {
    self.vtable.bindTexture(self.ptr, texture, sampler);
}

pub inline fn bindCurveBand(self: *const Pipeline, curve_tex: *Texture, band_tex: *Texture) void {
    self.vtable.bindCurveBand(self.ptr, curve_tex, band_tex);
}
