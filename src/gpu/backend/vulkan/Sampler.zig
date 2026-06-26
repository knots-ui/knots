const std = @import("std");
const vk = @import("vk");
const CommonSampler = @import("gpu").Sampler;
const Context = @import("Context.zig");

const Sampler = @This();

const FilterMode = CommonSampler.FilterMode;
const AddressMode = CommonSampler.AddressMode;
const Desc = CommonSampler.Desc;

sampler: vk.Sampler,
vkd: vk.DeviceWrapper,
device: vk.Device,

pub fn create(_: std.mem.Allocator, ctx: *Context, desc: Desc) !Sampler {
    const sampler = try ctx.vkd.createSampler(ctx.device, &.{
        .mag_filter = toVkFilter(desc.mag_filter),
        .min_filter = toVkFilter(desc.min_filter),
        .mipmap_mode = .nearest,
        .address_mode_u = toVkAddressMode(desc.address_mode_u),
        .address_mode_v = toVkAddressMode(desc.address_mode_v),
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = .false,
        .max_anisotropy = 1,
        .compare_enable = .false,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_opaque_black,
        .unnormalized_coordinates = .false,
    }, null);

    return .{
        .sampler = sampler,
        .vkd = ctx.vkd,
        .device = ctx.device,
    };
}

pub fn deinit(self: *Sampler) void {
    self.vkd.destroySampler(self.device, self.sampler, null);
}

fn toVkFilter(mode: FilterMode) vk.Filter {
    return switch (mode) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

fn toVkAddressMode(mode: AddressMode) vk.SamplerAddressMode {
    return switch (mode) {
        .clamp_to_edge => .clamp_to_edge,
        .repeat => .repeat,
        .mirror_repeat => .mirrored_repeat,
    };
}
