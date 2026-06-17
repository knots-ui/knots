const std = @import("std");
const math = @import("math");
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
    scroll,
    scroll_x,
    scroll_y,
    hidden,

    pub fn isScroll(self: Overflow) bool {
        return self == .scroll or self == .scroll_x or self == .scroll_y;
    }
};

pub const ScrollMetrics = struct {
    has_x: bool = false,
    has_y: bool = false,
    viewport_w: f32 = 0,
    viewport_h: f32 = 0,
    max_offset: math.Vec2 = .{ 0, 0 },
};

pub fn scrollMetrics(overflow: Overflow, box: math.Rect, content_w: f32, content_h: f32, thickness: f32) ScrollMetrics {
    const box_w = box.w();
    const box_h = box.h();
    var viewport_w = box_w;
    var viewport_h = box_h;
    var has_x = false;
    var has_y = false;

    switch (overflow) {
        .scroll_x => has_x = content_w > box_w and box_w > thickness,
        .scroll_y => has_y = content_h > box_h and box_h > thickness,
        .scroll => {
            has_x = content_w > box_w and box_w > thickness;
            has_y = content_h > box_h and box_h > thickness;

            if (has_y) viewport_w = @max(0, box_w - thickness);
            if (has_x) viewport_h = @max(0, box_h - thickness);
        },
        else => {},
    }

    return .{
        .has_x = has_x,
        .has_y = has_y,
        .viewport_w = viewport_w,
        .viewport_h = viewport_h,
        .max_offset = .{
            if (has_x) @max(0, content_w - viewport_w) else 0,
            if (has_y) @max(0, content_h - viewport_h) else 0,
        },
    };
}

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
// Parent-local offset applied during layout. Only honored when position == .absolute.
offset: [2]f32,

// internal routing state
input_scope: Id = INVALID_ID,

// computed by layout passes
box: math.Rect = .zero,
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
    focusable: bool = false,
    overflow: Overflow = .visible,
    position: Position = .static,
    z_index: u8 = 0,
    offset: [2]f32 = .{ 0, 0 },
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
            .offset = self.offset,
        };
    }
};
