const wgpu = @import("wgpu");
const CommonSampler = @import("gpu").Sampler;

const Sampler = @This();

const FilterMode = CommonSampler.FilterMode;
const AddressMode = CommonSampler.AddressMode;
const Desc = CommonSampler.Desc;

sampler: wgpu.Sampler,

pub fn create(device: wgpu.Device, desc: Desc) !Sampler {
    const sampler = try device.createSampler(.{
        .mag_filter = toWgpuFilter(desc.mag_filter),
        .min_filter = toWgpuFilter(desc.min_filter),
        .address_mode_u = toWgpuAddressMode(desc.address_mode_u),
        .address_mode_v = toWgpuAddressMode(desc.address_mode_v),
    });

    return .{
        .sampler = sampler,
    };
}

pub fn deinit(self: *Sampler) void {
    self.sampler.deinit();
}

fn toWgpuFilter(mode: FilterMode) wgpu.Sampler.FilterMode {
    return switch (mode) {
        .nearest => .nearest,
        .linear => .linear,
    };
}

fn toWgpuAddressMode(mode: AddressMode) wgpu.Sampler.AddressMode {
    return switch (mode) {
        .clamp_to_edge => .clamp_to_edge,
        .repeat => .repeat,
        .mirror_repeat => .mirror_repeat,
    };
}
