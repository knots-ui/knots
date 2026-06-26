pub const Window = @import("Window.zig");

pub const Key = enum(i32) {
    space = 32,
    apostrophe = 39,
    comma = 44,
    minus = 45,
    period = 46,
    slash = 47,
    @"0" = 48,
    @"1" = 49,
    @"2" = 50,
    @"3" = 51,
    @"4" = 52,
    @"5" = 53,
    @"6" = 54,
    @"7" = 55,
    @"8" = 56,
    @"9" = 57,
    semicolon = 59,
    equal = 61,
    a = 65,
    b = 66,
    c = 67,
    d = 68,
    e = 69,
    f = 70,
    g = 71,
    h = 72,
    i = 73,
    j = 74,
    k = 75,
    l = 76,
    m = 77,
    n = 78,
    o = 79,
    p = 80,
    q = 81,
    r = 82,
    s = 83,
    t = 84,
    u = 85,
    v = 86,
    w = 87,
    x = 88,
    y = 89,
    z = 90,
    left_bracket = 91,
    backslash = 92,
    right_bracket = 93,
    grave_accent = 96,
    world_1 = 161,
    world_2 = 162,
    escape = 256,
    enter = 257,
    tab = 258,
    backspace = 259,
    insert = 260,
    delete = 261,
    right = 262,
    left = 263,
    down = 264,
    up = 265,
    page_up = 266,
    page_down = 267,
    home = 268,
    end = 269,
    caps_lock = 280,
    scroll_lock = 281,
    num_lock = 282,
    print_screen = 283,
    pause = 284,
    f1 = 290,
    f2 = 291,
    f3 = 292,
    f4 = 293,
    f5 = 294,
    f6 = 295,
    f7 = 296,
    f8 = 297,
    f9 = 298,
    f10 = 299,
    f11 = 300,
    f12 = 301,
    f13 = 302,
    f14 = 303,
    f15 = 304,
    f16 = 305,
    f17 = 306,
    f18 = 307,
    f19 = 308,
    f20 = 309,
    f21 = 310,
    f22 = 311,
    f23 = 312,
    f24 = 313,
    f25 = 314,
    kp_0 = 320,
    kp_1 = 321,
    kp_2 = 322,
    kp_3 = 323,
    kp_4 = 324,
    kp_5 = 325,
    kp_6 = 326,
    kp_7 = 327,
    kp_8 = 328,
    kp_9 = 329,
    kp_decimal = 330,
    kp_divide = 331,
    kp_multiply = 332,
    kp_subtract = 333,
    kp_add = 334,
    kp_enter = 335,
    kp_equal = 336,
    left_shift = 340,
    left_control = 341,
    left_alt = 342,
    left_super = 343,
    right_shift = 344,
    right_control = 345,
    right_alt = 346,
    right_super = 347,
    menu = 348,
    _,
};

pub const Config = struct {
    height: u32,
    width: u32,
    title: []const u8,
    resizable: bool = true,
    min_size: ?Size = null,
    max_size: ?Size = null,
    canvas_selector: ?[:0]const u8 = null,
};

pub const MouseButton = enum(u3) {
    left,
    right,
    middle,
    back,
    forward,
};

pub const mouse_button_count = @typeInfo(MouseButton).@"enum".fields.len;

pub const MouseButtonState = struct {
    down: bool = false,
    pressed: bool = false,
    released: bool = false,
    pressed_pos: ?[2]f64 = null,
    released_pos: ?[2]f64 = null,
};

pub const ScrollInput = struct {
    pixel: [2]f32 = .{ 0, 0 },
    line: [2]f32 = .{ 0, 0 },
    page: [2]f32 = .{ 0, 0 },

    pub fn isZero(self: ScrollInput) bool {
        return self.pixel[0] == 0 and self.pixel[1] == 0 and
            self.line[0] == 0 and self.line[1] == 0 and
            self.page[0] == 0 and self.page[1] == 0;
    }

    pub fn add(self: *ScrollInput, other: ScrollInput) void {
        self.pixel[0] += other.pixel[0];
        self.pixel[1] += other.pixel[1];
        self.line[0] += other.line[0];
        self.line[1] += other.line[1];
        self.page[0] += other.page[0];
        self.page[1] += other.page[1];
    }
};

pub const Input = struct {
    focused: bool = true,
    pos: [2]f64,
    mouse: [mouse_button_count]MouseButtonState = @splat(.{}),
    scroll: ScrollInput = .{},
    chars: []const u21 = &.{},
    key_events: []const KeyEvent = &.{},
    key_down: *const [key_count]bool = &no_keys_down,
    shift_held: bool = false,
    ctrl_held: bool = false,
    alt_held: bool = false,
    super_held: bool = false,

    pub inline fn mouseButton(self: *const Input, button: MouseButton) *const MouseButtonState {
        return &self.mouse[@intFromEnum(button)];
    }

    pub fn keyPressed(self: Input, key: Key) bool {
        for (self.key_events) |event| if (event.key == key and event.action == .press) return true;
        return false;
    }

    pub fn keyRepeated(self: Input, key: Key) bool {
        for (self.key_events) |event| if (event.key == key and event.action == .repeat) return true;
        return false;
    }

    pub fn keyReleased(self: Input, key: Key) bool {
        for (self.key_events) |event| if (event.key == key and event.action == .release) return true;
        return false;
    }

    pub fn keyDown(self: Input, key: Key) bool {
        const value = @intFromEnum(key);
        return value >= 0 and value < key_count and self.key_down[@intCast(value)];
    }
};

pub const KeyAction = enum(u8) { release, press, repeat };

pub const Mods = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    _pad: u4 = 0,
};

pub const KeyEvent = struct {
    key: Key,
    action: KeyAction,
    mods: Mods,
};

pub const key_count = @intFromEnum(Key.menu) + 1;
pub const no_keys_down: [key_count]bool = @splat(false);

pub const Size = struct { width: u32, height: u32 };

pub const ResizeEvent = struct {
    logical: Size,
    physical: Size,
    content_scale: f32,
};

pub const FrameHandler = struct {
    ctx: *anyopaque,
    step: *const fn (*anyopaque) void,
};

pub const DisplayMode = enum {
    windowed,
    fullscreen,
};

pub const CursorShape = enum {
    default,
    text,
    pointer,
    crosshair,
    move,
    resize_horizontal,
    resize_vertical,
    resize_diagonal_nw_se,
    resize_diagonal_ne_sw,
    not_allowed,
};
