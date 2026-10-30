const std = @import("std");
const Element = @import("layout").Element;
const math = @import("math");
const grapheme = @import("text").unicode.grapheme;

pub const root_id: Element.Id = 0;
pub const nodes_max: u32 = 4096;
pub const actions_max: u32 = 64;
pub const text_bytes_max: u32 = 4096;
pub const text_run_index = std.math.maxInt(usize);

/// Characters are graphemes, split where one is longer than a `u8` length allows.
pub const CharacterIterator = struct {
    text: []const u8,
    graphemes: grapheme.Iterator,
    offset: usize = 0,
    grapheme_end: usize = 0,

    pub fn init(text: []const u8) CharacterIterator {
        return .{ .text = text, .graphemes = .init(text) };
    }

    pub fn next(self: *CharacterIterator) ?u8 {
        if (self.offset >= self.text.len) return null;
        if (self.offset >= self.grapheme_end) self.grapheme_end = self.graphemes.next().?;
        var len = @min(self.grapheme_end - self.offset, std.math.maxInt(u8));
        while (self.offset + len < self.grapheme_end and self.text[self.offset + len] & 0xC0 == 0x80) len -= 1;
        self.offset += len;
        return @intCast(len);
    }
};

pub fn byteToCharacter(text: []const u8, byte: u32) u32 {
    var iterator = CharacterIterator.init(text);
    var characters: u32 = 0;
    while (iterator.next()) |_| {
        if (iterator.offset > byte) break;
        characters += 1;
    }
    return characters;
}

pub fn characterToByte(text: []const u8, character: u32) u32 {
    var iterator = CharacterIterator.init(text);
    var index: u32 = 0;
    while (index < character) : (index += 1) {
        _ = iterator.next() orelse break;
    }
    return @intCast(iterator.offset);
}

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

test "characters are graphemes" {
    const value = "e\u{0301}x\u{1F468}\u{200D}\u{1F469}";
    try std.testing.expectEqual(@as(u32, 1), byteToCharacter(value, 3));
    try std.testing.expectEqual(@as(u32, 0), byteToCharacter(value, 2));
    try std.testing.expectEqual(@as(u32, 3), byteToCharacter(value, @intCast(value.len)));
    try std.testing.expectEqual(@as(u32, 4), characterToByte(value, 2));
    var lengths: [8]u8 = undefined;
    var count: usize = 0;
    var iterator = CharacterIterator.init(value);
    while (iterator.next()) |len| : (count += 1) lengths[count] = len;
    try std.testing.expectEqualSlices(u8, &.{ 3, 1, 11 }, lengths[0..count]);
}
