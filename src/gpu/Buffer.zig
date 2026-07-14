const std = @import("std");

pub const Usage = struct {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    copy_dst: bool = false,
    copy_src: bool = false,
    storage: bool = false,
};

pub const Desc = struct {
    size: usize,
    usage: Usage,
    initial_data: ?[]const u8 = null,
    label: []const u8 = "",
};

pub fn validateDesc(desc: Desc) !void {
    if (desc.size == 0) return error.InvalidBufferSize;
    if (desc.initial_data) |data| {
        if (data.len > desc.size) return error.InitialBufferDataTooLarge;
        if (data.len % 4 != 0) return error.UnalignedInitialBufferData;
    }
    if (std.meta.eql(effectiveUsage(desc), Usage{})) return error.InvalidBufferUsage;
}

pub fn effectiveUsage(desc: Desc) Usage {
    var usage = desc.usage;
    if (desc.initial_data) |data| {
        if (data.len != 0) usage.copy_dst = true;
    }
    return usage;
}
