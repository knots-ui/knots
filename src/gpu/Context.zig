pub const WindowHandle = union(enum) {
    macos: union(enum) {
        ns_view: *anyopaque,
        ns_window: *anyopaque,
    },
    windows: struct {
        hwnd: *anyopaque,
        hinstance: *anyopaque,
    },
    linux: union(enum) {
        x11: struct {
            display: *anyopaque,
            window: u64,
        },
        wayland: struct {
            display: *anyopaque,
            surface: *anyopaque,
        },
    },
    emscripten: struct {
        selector: []const u8,
    },
};

pub const PresentMode = enum {
    fifo,
    fifo_relaxed,
    immediate,
    mailbox,
};

pub const Config = struct {
    window_width: u32,
    window_height: u32,
    present_mode: PresentMode,
};
