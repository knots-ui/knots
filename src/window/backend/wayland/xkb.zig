pub const Context = opaque {};
pub const Keymap = opaque {};
pub const State = opaque {};

pub const keycode_t = u32;
pub const mod_mask_t = u32;

pub const CONTEXT_NO_FLAGS: u32 = 0;
pub const KEYMAP_COMPILE_NO_FLAGS: u32 = 0;
pub const KEYMAP_FORMAT_TEXT_V1: u32 = 1;
pub const STATE_MODS_EFFECTIVE: u32 = 1 << 3;

pub const KEY_NoSymbol: u32 = 0;

pub extern fn xkb_context_new(flags: u32) ?*Context;
pub extern fn xkb_context_unref(context: *Context) void;

pub extern fn xkb_keymap_new_from_string(
    context: *Context,
    string: [*:0]const u8,
    format: u32,
    flags: u32,
) ?*Keymap;
pub extern fn xkb_keymap_new_from_buffer(
    context: *Context,
    buffer: [*]const u8,
    length: usize,
    format: u32,
    flags: u32,
) ?*Keymap;
pub extern fn xkb_keymap_unref(keymap: *Keymap) void;

pub extern fn xkb_state_new(keymap: *Keymap) ?*State;
pub extern fn xkb_state_unref(state: *State) void;
pub extern fn xkb_state_update_mask(
    state: *State,
    depressed_mods: mod_mask_t,
    latched_mods: mod_mask_t,
    locked_mods: mod_mask_t,
    depressed_layout: u32,
    latched_layout: u32,
    locked_layout: u32,
) u32;
pub extern fn xkb_state_key_get_utf32(state: *State, key: keycode_t) u32;
pub extern fn xkb_state_mod_name_is_active(state: *State, name: [*:0]const u8, ty: u32) c_int;
