const input_types = @import("input");
const std = @import("std");
const render = @import("render");
const UI = @import("UI.zig");
const Theme = @import("style").Theme;

pub const modules_max: u32 = 30;
pub const host_overlay_layer_min: u8 = 240;

pub const State = struct {
    ui: *UI,
    arena: std.mem.Allocator,
    arena_capacity: usize,
    input: *const input_types.FrameInput,
    effects: Effects,
    active: bool,
    generation: u64,
    contribution_calls: std.ArrayList(ContributionCall) = .empty,

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

pub const Contribution = struct {
    identity: u64,
    packet: render.Packet,
};

pub const ContributionCall = struct {
    slot: @import("layout").Element.Slot,
    identity: u64,
    context: *anyopaque,
    render: *const fn (*anyopaque, *const input_types.FrameInput, *const Theme, @import("math").Rect, std.mem.Allocator) anyerror!ModuleOutput,
};

pub const ModuleOutput = struct {
    packet: render.Packet,
    cursor_shape: input_types.CursorShape = .default,
    capture_pointer: bool = false,
    capture_keyboard: bool = false,
    text_input: bool = false,
    redraw: bool = false,
    close: bool = false,
    clipboard_write: ?[]const u8 = null,
    theme: ?Theme = null,
};

pub const Output = struct {
    accessibility: @import("Accessibility.zig").Snapshot = .{},
    contributions: []const Contribution = &.{},
    packet: render.Packet,
    host_overlay: ?render.Packet = null,
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

pub fn frameGeneration(self: *const Frame) u64 {
    std.debug.assert(self._generation > 0);
    return self._generation;
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

/// Reserve a bounded region for a module contribution. The host invokes the
/// module after layout and owns final input routing and composition.
pub fn contribute(self: *Frame, key: @import("Key.zig"), identity: u64, context: *anyopaque, callback: @FieldType(ContributionCall, "render")) !void {
    const active = self.state();
    std.debug.assert(identity != 0);
    std.debug.assert(active.active);
    if (active.contribution_calls.items.len == modules_max) return error.TooManyModules;
    for (active.contribution_calls.items) |entry| {
        if (entry.identity == identity) return error.RepeatedModule;
    }
    _ = try active.ui.open(key, .{ .width = .grow(), .height = .grow(), .overflow = .hidden, .interactive = true }, .none);
    const slot = active.ui.currentSlot();
    const layer = active.ui.currentLayer();
    active.ui.close();
    if (layer.index() >= host_overlay_layer_min) return error.InvalidModuleLayer;
    try active.contribution_calls.append(active.arena, .{ .slot = slot, .identity = identity, .context = context, .render = callback });
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
                    if (id != UI.INVALID_ID and !self.ui().culling()) {
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
