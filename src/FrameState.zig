const std = @import("std");
const input_types = @import("input");
const UI = @import("ui").UI;

ui: *UI,
arena: std.mem.Allocator,
arena_capacity: usize,
input: *const input_types.FrameInput,
effects: Effects,
active: bool,

pub const Effects = struct {
    redraw: bool = false,
    close: bool = false,
    clipboard_write: ?[]const u8 = null,
};

pub fn init(
    ui: *UI,
    arena: std.mem.Allocator,
    arena_capacity: usize,
    input_value: *const input_types.FrameInput,
) @This() {
    return .{
        .ui = ui,
        .arena = arena,
        .arena_capacity = arena_capacity,
        .input = input_value,
        .effects = .{},
        .active = true,
    };
}
