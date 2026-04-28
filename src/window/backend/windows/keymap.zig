const win32 = @import("win32").everything;
const window = @import("window");

const Key = window.Key;

const vk_to_key: [256]Key = blk: {
    var t: [256]Key = undefined;
    for (&t) |*slot| slot.* = @enumFromInt(0);

    var c: u8 = 'A';
    while (c <= 'Z') : (c += 1) t[c] = @enumFromInt(@as(i32, c));

    var d: u8 = '0';
    while (d <= '9') : (d += 1) t[d] = @enumFromInt(@as(i32, d));

    var f: usize = 0;
    while (f < 24) : (f += 1) t[0x70 + f] = @enumFromInt(@intFromEnum(Key.f1) + @as(i32, @intCast(f)));

    var k: usize = 0;
    while (k < 10) : (k += 1) t[0x60 + k] = @enumFromInt(@intFromEnum(Key.kp_0) + @as(i32, @intCast(k)));

    t[0x08] = .backspace;
    t[0x09] = .tab;
    t[0x0D] = .enter;
    t[0x13] = .pause;
    t[0x14] = .caps_lock;
    t[0x1B] = .escape;
    t[0x20] = .space;
    t[0x21] = .page_up;
    t[0x22] = .page_down;
    t[0x23] = .end;
    t[0x24] = .home;
    t[0x25] = .left;
    t[0x26] = .up;
    t[0x27] = .right;
    t[0x28] = .down;
    t[0x2C] = .print_screen;
    t[0x2D] = .insert;
    t[0x2E] = .delete;
    t[0x5B] = .left_super;
    t[0x5C] = .right_super;
    t[0x5D] = .menu;
    t[0x6A] = .kp_multiply;
    t[0x6B] = .kp_add;
    t[0x6D] = .kp_subtract;
    t[0x6E] = .kp_decimal;
    t[0x6F] = .kp_divide;
    t[0x90] = .num_lock;
    t[0x91] = .scroll_lock;
    t[0xBA] = .semicolon;
    t[0xBB] = .equal;
    t[0xBC] = .comma;
    t[0xBD] = .minus;
    t[0xBE] = .period;
    t[0xBF] = .slash;
    t[0xC0] = .grave_accent;
    t[0xDB] = .left_bracket;
    t[0xDC] = .backslash;
    t[0xDD] = .right_bracket;
    t[0xDE] = .apostrophe;

    break :blk t;
};

const MAPVK_VSC_TO_VK_EX: u32 = 3;

pub fn translateVk(vk: u32, lparam: win32.LPARAM) Key {
    const lp: u64 = @bitCast(@as(i64, lparam));
    const scancode: u32 = @intCast((lp >> 16) & 0xFF);
    const extended: bool = ((lp >> 24) & 1) == 1;
    return switch (vk) {
        @intFromEnum(win32.VK_SHIFT) => blk: {
            const resolved = win32.MapVirtualKeyW(scancode, MAPVK_VSC_TO_VK_EX);
            break :blk if (resolved == @intFromEnum(win32.VK_LSHIFT)) .left_shift else .right_shift;
        },
        @intFromEnum(win32.VK_CONTROL) => if (extended) .right_control else .left_control,
        @intFromEnum(win32.VK_MENU) => if (extended) .right_alt else .left_alt,
        @intFromEnum(win32.VK_RETURN) => if (extended) .kp_enter else .enter,
        else => if (vk < vk_to_key.len) vk_to_key[vk] else @enumFromInt(0),
    };
}
