const input = @import("input");

pub const Window = @import("Window.zig");

test {
    _ = @import("window_drop_paths");
}

pub const Config = struct {
    height: u32,
    width: u32,
    title: []const u8,
    resizable: bool = true,
    min_size: ?input.Size = null,
    max_size: ?input.Size = null,
    canvas_selector: ?[:0]const u8 = null,
};

pub const ResizeEvent = struct {
    logical: input.Size,
    physical: input.Size,
    content_scale: f32,
};

pub const FrameHandler = struct {
    ctx: *anyopaque,
    step: *const fn (ctx: *anyopaque) void,
};

pub const DisplayMode = enum {
    windowed,
    fullscreen,
};
