pub const Format = enum { rgba8, rgba8_srgb, bgra8, bgra8_srgb, r8, rgba32f, rgba32u };

pub const Usage = struct {
    texture_binding: bool = false,
    copy_dst: bool = false,
    copy_src: bool = false,
    render_attachment: bool = false,
};

pub const Desc = struct {
    width: u32,
    height: u32,
    format: Format,
    usage: Usage,
    label: []const u8 = "",
};
