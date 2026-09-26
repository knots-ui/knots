const std = @import("std");
const Element = @import("layout").Element;
const math = @import("math");

pub const root_id: Element.Id = 0;
pub const nodes_max: u32 = 4096;
pub const actions_max: u32 = 64;
pub const text_bytes_max: u32 = 4096;
pub const text_run_index = std.math.maxInt(usize);

pub const Action = enum(u8) {
    focus,
    click,
    collapse,
    expand,
    decrement,
    increment,
    set_value,
    replace_selected_text,
    set_text_selection,
};

pub const ActionRequest = struct {
    id: Element.Id,
    action: Action,
    value_text: ?[]const u8 = null,
    value_number: ?f64 = null,
    selection_anchor: ?u32 = null,
    selection_focus: ?u32 = null,
};

pub const Snapshot = struct {
    revision: u64 = 0,
    /// Semantic bounds are expressed in logical UI units. Native adapters
    /// convert them to physical pixels before handing them to AccessKit.
    content_scale: f32 = 1,
    nodes: []const Node = &.{},
    children: []const Element.Id = &.{},
    focus: Element.Id = root_id,
};

pub const Role = enum {
    generic,
    text_run,
    button,
    checkbox,
    radio,
    slider,
    text_input,
    select,
    list_box,
    list_box_option,
    dialog,
    menu,
    tooltip,
};

pub const State = struct {
    disabled: bool = false,
    focused: bool = false,
    checked: ?bool = null,
    selected: ?bool = null,
    expanded: ?bool = null,
    multiline: bool = false,
    selection_anchor: ?u32 = null,
    selection_focus: ?u32 = null,
    value_text: ?[]const u8 = null,
    value_number: ?f32 = null,
    min: ?f32 = null,
    max: ?f32 = null,
};

pub const Metadata = struct {
    role: Role,
    parent: ?Element.Id = null,
    text_run_id: ?Element.Id = null,
    name: []const u8 = &.{},
    state: State = .{},
};

pub const Node = struct {
    id: Element.Id,
    parent: Element.Id = Element.INVALID_ID,
    text_run_id: ?Element.Id = null,
    role: Role,
    name: []const u8 = &.{},
    bounds: math.Rect = .zero,
    state: State = .{},
    child_start: u32 = 0,
    child_count: u32 = 0,
    actions: std.EnumSet(Action) = .empty,
};

pub const root_node: Node = .{ .id = root_id, .role = .generic };

pub fn freeNodes(allocator: std.mem.Allocator, nodes: []Node) void {
    for (nodes) |node| {
        if (node.name.len > 0) allocator.free(node.name);
        if (node.state.value_text) |value| if (value.len > 0) allocator.free(value);
    }
}
