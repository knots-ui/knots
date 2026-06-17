const Element = @import("layout").Element;
const math = @import("math");

pub const Role = enum {
    generic,
    button,
    checkbox,
    radio,
    slider,
    text_input,
    select,
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
    value_text: ?[]const u8 = null,
    value_number: ?f32 = null,
    min: ?f32 = null,
    max: ?f32 = null,
};

pub const Metadata = struct {
    role: Role,
    name: []const u8 = &.{},
    state: State = .{},
};

pub const Node = struct {
    id: Element.Id,
    parent: Element.Id = Element.INVALID_ID,
    role: Role,
    name: []const u8 = &.{},
    bounds: math.Rect = .zero,
    state: State = .{},
};
