const std = @import("std");
const Grid = @import("Grid.zig");

pub const Id = u64;
pub const GridTemplate = Grid.Template;
pub const GridPlacement = Grid.Placement;

pub const INVALID_ID: Id = std.math.maxInt(u64);

pub const Slot = u32;
pub const INVALID_SLOT: Slot = std.math.maxInt(u32);

pub const sizing = struct {
    pub const Kind = enum {
        fixed,
        fit,
        grow,
        percent,
    };

    pub const Axis = struct {
        kind: Kind,
        value: f32 = 0, // used for fixed/percent
        min: f32 = 0,
        max: f32 = std.math.floatMax(f32),

        const Self = @This();

        pub fn fixed(v: f32) Self {
            return .{ .kind = .fixed, .value = v };
        }

        pub fn grow() Self {
            return .{ .kind = .grow };
        }

        pub fn fit() Self {
            return .{ .kind = .fit };
        }

        pub fn percent(v: f32) Self {
            return .{ .kind = .percent, .value = v };
        }
    };
};

pub const Align = enum {
    start,
    center,
    end,
    stretch,
};

pub const Justify = enum {
    start,
    center,
    end,
    space_between,
    space_around,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Padding = struct {
    value: [4]f32,

    pub fn init(t: f32, r: f32, b: f32, l: f32) Padding {
        return Padding{ .value = .{ t, r, b, l } };
    }

    pub fn top(self: Padding) f32 {
        return self.value[0];
    }

    pub fn right(self: Padding) f32 {
        return self.value[1];
    }

    pub fn bottom(self: Padding) f32 {
        return self.value[2];
    }

    pub fn left(self: Padding) f32 {
        return self.value[3];
    }
};

pub const Direction = enum {
    row,
    column,
    layer,
    grid,
};

pub const Position = enum {
    static,
    absolute,
};

pub const Overflow = enum {
    visible,
    scroll_x,
    scroll_y,
    hidden,

    pub fn isScroll(self: Overflow) bool {
        return self == .scroll_x or self == .scroll_y;
    }
};

id: Id = INVALID_ID,
parent: Slot = INVALID_SLOT,
first_child: Slot = INVALID_SLOT,
next_sibling: Slot = INVALID_SLOT,
last_child: Slot = INVALID_SLOT,
child_count: u32 = 0,

// config
width: sizing.Axis,
height: sizing.Axis,
padding: Padding,
gap: f32,
direction: Direction,
alignment: Align,
justify: Justify,
interactive: bool,
overflow: Overflow,
position: Position,
z_index: u8,

// computed by layout passes
box: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
intrinsic_w: f32 = 0,
intrinsic_h: f32 = 0,
content_w: f32 = 0,
content_h: f32 = 0,
subtree_end: Slot = INVALID_SLOT,

const Element = @This();

pub const Config = struct {
    width: sizing.Axis = .fit(),
    height: sizing.Axis = .fit(),
    padding: Padding = .init(0, 0, 0, 0),
    gap: f32 = 0,
    direction: Direction = .row,
    alignment: Align = .start,
    justify: Justify = .start,
    interactive: bool = false,
    overflow: Overflow = .visible,
    position: Position = .static,
    z_index: u8 = 0,
    grid_template: ?Grid.Template = null,
    grid_placement: ?Grid.Placement = null,

    pub fn toElement(self: Config) Element {
        return .{
            .width = self.width,
            .height = self.height,
            .padding = self.padding,
            .gap = self.gap,
            .direction = self.direction,
            .alignment = self.alignment,
            .justify = self.justify,
            .interactive = self.interactive,
            .overflow = self.overflow,
            .position = self.position,
            .z_index = self.z_index,
        };
    }
};
