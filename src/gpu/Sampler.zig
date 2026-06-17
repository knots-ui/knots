pub const FilterMode = enum { nearest, linear };
pub const AddressMode = enum { clamp_to_edge, repeat, mirror_repeat };

pub const Desc = struct {
    mag_filter: FilterMode = .linear,
    min_filter: FilterMode = .linear,
    address_mode_u: AddressMode = .clamp_to_edge,
    address_mode_v: AddressMode = .clamp_to_edge,
};
