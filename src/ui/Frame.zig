const input_types = @import("input");
const std = @import("std");
const render = @import("render");
const UI = @import("UI.zig");


pub const State = struct {
    ui: *UI,
    arena: std.mem.Allocator,
    arena_capacity: usize,
    input: *const input_types.FrameInput,
    effects: Effects,
    active: bool,
    generation: u64,

    pub const Effects = struct {
        redraw: bool = false,
        close: bool = false,
        clipboard_write: ?[]const u8 = null,
    };

    pub fn init(
        ui_value: *UI,
        arena_value: std.mem.Allocator,
        arena_capacity: usize,
        input_value: *const input_types.FrameInput,
        generation: u64,
    ) State {
        std.debug.assert(generation > 0);
        std.debug.assert(input_value.content_scale > 0);
        return .{
            .ui = ui_value,
            .arena = arena_value,
            .arena_capacity = arena_capacity,
            .input = input_value,
            .effects = .{},
            .active = true,
            .generation = generation,
        };
    }
};

pub const RenderFn = *const fn (*Frame) anyerror!void;

pub const Output = struct {
    packet: render.Packet,
    cursor_shape: input_types.CursorShape,
    capture_pointer: bool,
    capture_keyboard: bool,
    text_input: bool,
    redraw: bool,
    close: bool,
    clipboard_write: ?[]const u8,
};

_state: *State,
_generation: u64,

const Frame = @This();


pub fn deinit(self: *Frame) void {
    std.debug.assert(self._generation > 0);
    std.debug.assert(self._state.generation >= self._generation);
    if (self._state.generation == self._generation) self._state.active = false;
}

pub fn arena(self: *const Frame) std.mem.Allocator {
    return self.state().arena;
}

/// Arena capacity as measured at `beginFrame`; it does not grow during the frame.
pub fn arenaCapacity(self: *const Frame) usize {
    return self.state().arena_capacity;
}

pub fn ui(self: *const Frame) *UI {
    return self.state().ui;
}

pub fn input(self: *const Frame) *const input_types.FrameInput {
    return self.state().input;
}

pub fn requestRedraw(self: *Frame) void {
    self.state().effects.redraw = true;
}

pub fn requestClose(self: *Frame) void {
    self.state().effects.close = true;
}

pub fn writeClipboard(self: *Frame, value: []const u8) !void {
    const frame_state = self.state();
    frame_state.effects.clipboard_write = try frame_state.arena.dupe(u8, value);
}

pub fn pasteText(self: *const Frame) ?[]const u8 {
    return self.input().paste_text;
}

pub fn droppedPaths(self: *const Frame) []const []const u8 {
    return self.input().dropped_paths;
}

/// Register a component tree to be rendered in the UI.
pub fn e(self: *Frame, tree: anytype) !void {
    self.assertActive();
    const T = @TypeOf(tree);
    if (comptime isControlFlow(T)) {
        try tree.eval(self);
    } else if (comptime isComponent(T)) {
        _ = try tree.open(self);
        try tree.close(self);
    } else switch (@typeInfo(T)) {
        .@"fn" => try @call(.always_inline, tree, .{self}),
        .@"struct" => |structure| if (comptime isRenderable(T))
            try tree.render(self)
        else {
            comptime var index: usize = 0;
            inline while (index < structure.field_names.len) : (index += 1) {
                const value = @field(tree, structure.field_names[index]);
                if (comptime isComponent(@TypeOf(value)) and
                    index + 1 < structure.field_names.len and
                    isChildren(structure.field_types[index + 1]))
                {
                    const id = try value.open(self);
                    if (id != UI.INVALID_ID) {
                        try self.e(@field(tree, structure.field_names[index + 1]));
                    }
                    try value.close(self);
                    index += 1;
                } else {
                    try self.e(value);
                }
            }
        },
        else => @compileError("unexpected type in component tree: " ++ @typeName(T)),
    }
}

/// Render one interactive component and return its per-frame response.
///
/// Unlike callback fields, the response keeps application state in the
/// caller's lexical scope and does not require hidden frame context.
pub fn interact(self: *Frame, component: anytype) @TypeOf(component.interact(self)) {
    self.assertActive();
    return component.interact(self);
}

fn assertActive(self: *const Frame) void {
    _ = self.state();
}

fn state(self: *const Frame) *State {
    std.debug.assert(self._state.active);
    std.debug.assert(self._state.generation == self._generation);
    return self._state;
}

fn isControlFlow(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "eval"),
        else => false,
    };
}

fn isComponent(comptime T: type) bool {
    const Structure = switch (@typeInfo(T)) {
        .@"struct" => T,
        .pointer => |pointer| pointer.child,
        else => return false,
    };
    return @hasDecl(Structure, "open") and @hasDecl(Structure, "close");
}

fn isRenderable(comptime T: type) bool {
    if (!@hasDecl(T, "render")) return false;
    return @TypeOf(T.render) == fn (*const T, *Frame) anyerror!void;
}

fn isChildren(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |structure| structure.is_tuple,
        else => false,
    };
}
