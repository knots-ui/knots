const std = @import("std");
const Element = @import("Element.zig");
const ElementPool = @import("ElementPool.zig");
const Grid = @import("Grid.zig");

// Element.Id is a well-distributed Wyhash output (see Key.hash), so
// identity-hashing is correct here.
const IdContext = struct {
    pub fn hash(_: IdContext, id: Element.Id) u64 {
        return id;
    }
    pub fn eql(_: IdContext, a: Element.Id, b: Element.Id) bool {
        return a == b;
    }
};

const IdToSlotMap = std.HashMapUnmanaged(
    Element.Id,
    Element.Slot,
    IdContext,
    std.hash_map.default_max_load_percentage,
);

const AxisInfo = struct {
    is_row: bool,
    main_size: f32,
    cross_size: f32,
    pad_main_start: f32,
    pad_main_end: f32,
    pad_cross_start: f32,
    pad_cross_end: f32,

    fn init(el: *const Element) AxisInfo {
        if (el.direction == .row) {
            return .{
                .is_row = true,
                .main_size = el.box.w(),
                .cross_size = el.box.h() - el.padding.top() - el.padding.bottom(),
                .pad_main_start = el.padding.left(),
                .pad_main_end = el.padding.right(),
                .pad_cross_start = el.padding.top(),
                .pad_cross_end = el.padding.bottom(),
            };
        } else {
            return .{
                .is_row = false,
                .main_size = el.box.h(),
                .cross_size = el.box.w() - el.padding.left() - el.padding.right(),
                .pad_main_start = el.padding.top(),
                .pad_main_end = el.padding.bottom(),
                .pad_cross_start = el.padding.left(),
                .pad_cross_end = el.padding.right(),
            };
        }
    }

    fn available(self: AxisInfo) f32 {
        return self.main_size - self.pad_main_start - self.pad_main_end;
    }

    fn childMainSize(self: AxisInfo, child: *const Element) f32 {
        return if (self.is_row) child.box.w() else child.box.h();
    }

    fn setChildMainSize(self: AxisInfo, child: *Element, v: f32) void {
        if (self.is_row) child.box.setW(v) else child.box.setH(v);
    }

    fn setChildCrossSize(self: AxisInfo, child: *Element, v: f32) void {
        if (self.is_row) child.box.setH(v) else child.box.setW(v);
    }

    fn childMainKind(self: AxisInfo, child: *const Element) Element.sizing.Kind {
        return if (self.is_row) child.width.kind else child.height.kind;
    }

    fn childCrossKind(self: AxisInfo, child: *const Element) Element.sizing.Kind {
        return if (self.is_row) child.height.kind else child.width.kind;
    }

    fn childCrossSize(self: AxisInfo, child: *const Element) f32 {
        return if (self.is_row) child.box.h() else child.box.w();
    }

    fn childMainMin(self: AxisInfo, child: *const Element) f32 {
        return if (self.is_row) child.width.min else child.height.min;
    }

    fn childMainMax(self: AxisInfo, child: *const Element) f32 {
        return if (self.is_row) child.width.max else child.height.max;
    }

    fn childCrossMin(self: AxisInfo, child: *const Element) f32 {
        return if (self.is_row) child.height.min else child.width.min;
    }

    fn childCrossMax(self: AxisInfo, child: *const Element) f32 {
        return if (self.is_row) child.height.max else child.width.max;
    }

    fn childMainPercent(self: AxisInfo, child: *const Element) f32 {
        return if (self.is_row) child.width.value else child.height.value;
    }

    fn childCrossPercent(self: AxisInfo, child: *const Element) f32 {
        return if (self.is_row) child.height.value else child.width.value;
    }
};

const Measurement = struct {
    used: f32,
    fixed_used: f32,
    grow_count: f32,
    static_count: u32,
};

allocator: std.mem.Allocator,
pool: ElementPool,
stack: std.ArrayList(Element.Slot) = .empty,
root_slot: Element.Slot = Element.INVALID_SLOT,
z_used: std.StaticBitSet(256),
z_slots: std.ArrayList(Element.Slot) = .empty,
z_offsets: [257]u32 = @splat(0),
id_to_slot: IdToSlotMap = .empty,
has_scroll: bool = false,
scroll_slots: std.ArrayList(Element.Slot) = .empty,

// Sparse side-tables, grid templates live on parent slots, placements on child slots.
grid_templates: std.AutoHashMapUnmanaged(Element.Slot, Grid.Template) = .empty,
grid_placements: std.AutoHashMapUnmanaged(Element.Slot, Grid.Placement) = .empty,

const Context = @This();

pub const LayoutError = std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator) Context {
    return .{
        .allocator = allocator,
        .pool = .{},
        .z_used = .empty,
    };
}

pub fn deinit(self: *Context) void {
    self.stack.deinit(self.allocator);
    self.z_slots.deinit(self.allocator);
    self.id_to_slot.deinit(self.allocator);
    self.grid_templates.deinit(self.allocator);
    self.grid_placements.deinit(self.allocator);
    self.scroll_slots.deinit(self.allocator);
    self.pool.deinit(self.allocator);
}

pub fn reset(self: *Context) void {
    self.pool.reset();
    self.stack.clearRetainingCapacity();
    self.z_slots.clearRetainingCapacity();
    self.id_to_slot.clearRetainingCapacity();
    self.grid_templates.clearRetainingCapacity();
    self.grid_placements.clearRetainingCapacity();
    self.root_slot = Element.INVALID_SLOT;
    self.z_used = .empty;
    self.has_scroll = false;
    self.scroll_slots.clearRetainingCapacity();
}

pub fn open(self: *Context, id: Element.Id, config: Element.Config) !Element.Slot {
    std.debug.assert(self.slotForId(id) == null);

    const slot = try self.pool.append(self.allocator, id, config.toElement());
    try self.id_to_slot.putContext(self.allocator, id, slot, .{});
    if (config.grid_template) |t| try self.grid_templates.put(self.allocator, slot, t);
    if (config.grid_placement) |p| try self.grid_placements.put(self.allocator, slot, p);

    const slot_el = blk: {
        if (self.stack.items.len > 0) {
            const parent_slot = self.stack.items[self.stack.items.len - 1];
            const parent = self.pool.get(parent_slot);

            if (parent.first_child == Element.INVALID_SLOT)
                parent.first_child = slot
            else
                self.pool.get(parent.last_child).next_sibling = slot;

            parent.last_child = slot;

            const child = self.pool.get(slot);
            child.parent = parent_slot;
            if (parent.z_index > child.z_index) child.z_index = parent.z_index;
            self.z_used.set(child.z_index);
            parent.child_count += 1;
            break :blk child;
        } else {
            self.root_slot = slot;
            const root = self.pool.get(slot);
            self.z_used.set(root.z_index);
            break :blk root;
        }
    };

    if (slot_el.overflow.isScroll()) {
        self.has_scroll = true;
        try self.scroll_slots.append(self.allocator, slot);
    }

    try self.stack.append(self.allocator, slot);
    return slot;
}

pub fn openRoot(self: *Context, id: Element.Id, config: Element.Config) !Element.Slot {
    std.debug.assert(self.slotForId(id) == null);

    const slot = try self.pool.append(self.allocator, id, config.toElement());
    try self.id_to_slot.putContext(self.allocator, id, slot, .{});
    if (config.grid_template) |t| try self.grid_templates.put(self.allocator, slot, t);
    if (config.grid_placement) |p| try self.grid_placements.put(self.allocator, slot, p);
    const el = self.pool.get(slot);
    self.z_used.set(el.z_index);
    if (el.overflow.isScroll()) {
        self.has_scroll = true;
        try self.scroll_slots.append(self.allocator, slot);
    }
    try self.stack.append(self.allocator, slot);
    return slot;
}

pub fn close(self: *Context) void {
    std.debug.assert(self.stack.items.len > 0);
    const slot = self.stack.pop().?;
    self.pool.get(slot).subtree_end = @intCast(self.pool.elements.items.len);
}

pub fn slotForId(self: *const Context, id: Element.Id) ?Element.Slot {
    return self.id_to_slot.getContext(id, .{});
}

pub fn buildZOrder(self: *Context) !void {
    const elements = self.pool.elements.items;
    const n: u32 = @intCast(elements.len);

    var counts: [256]u32 = @splat(0);
    for (elements) |el| counts[el.z_index] += 1;

    self.z_offsets[0] = 0;
    inline for (0..256) |z| self.z_offsets[z + 1] = self.z_offsets[z] + counts[z];

    try self.z_slots.resize(self.allocator, n);
    var write = counts;
    @memset(&write, 0);
    for (elements, 0..) |el, idx| {
        const z = el.z_index;
        self.z_slots.items[self.z_offsets[z] + write[z]] = @intCast(idx);
        write[z] += 1;
    }
}

pub fn zSlots(self: *const Context, z: u8) []const Element.Slot {
    return self.z_slots.items[self.z_offsets[z]..self.z_offsets[@as(u9, z) + 1]];
}

/// Returns true iff `slot` is in the subtree rooted at `ancestor`.
/// Uses the pre-order (= insertion order) and `subtree_end` set in `close()`:
/// `slot` is a strict descendant iff `ancestor < slot < subtree_end(ancestor)`.
pub fn isDescendantOf(self: *const Context, slot: Element.Slot, ancestor: Element.Slot) bool {
    if (slot == Element.INVALID_SLOT or ancestor == Element.INVALID_SLOT) return false;
    if (slot <= ancestor) return false;
    return slot < self.pool.elements.items[ancestor].subtree_end;
}

pub fn computeSizes(self: *Context) void {
    var i: Element.Slot = @intCast(self.pool.elements.items.len);
    while (i > 0) {
        i -= 1;
        const el = self.pool.get(i);

        {
            const initial: f32 = switch (el.width.kind) {
                .fixed => el.width.value,
                .percent => 0,
                .grow => 0,
                .fit => fitWidth(self, i, el),
            };
            el.box.setW(std.math.clamp(initial, el.width.min, el.width.max));
        }

        {
            const initial: f32 = switch (el.height.kind) {
                .fixed => el.height.value,
                .percent => 0,
                .grow => 0,
                .fit => fitHeight(self, i, el),
            };
            el.box.setH(std.math.clamp(initial, el.height.min, el.height.max));
        }
    }
}

fn fitWidth(self: *Context, slot: Element.Slot, el: *Element) f32 {
    if (el.intrinsic_w > 0)
        return el.intrinsic_w + el.padding.left() + el.padding.right();

    const pad_w = el.padding.left() + el.padding.right();

    if (el.direction == .grid) {
        const tpl = self.grid_templates.get(slot) orelse return pad_w;
        if (tpl.cols.len == 0) return pad_w;
        var sum: f32 = 0;
        for (tpl.cols) |t| switch (t) {
            .fixed => |v| sum += v,
            .fr => {},
        };
        if (tpl.cols.len > 1)
            sum += el.gap * @as(f32, @floatFromInt(tpl.cols.len - 1));
        return sum + pad_w;
    }

    var total = pad_w;
    var child_slot = el.first_child;
    var child_count: u32 = 0;
    while (child_slot != Element.INVALID_SLOT) {
        const child = self.pool.get(child_slot);
        if (child.position != .absolute) {
            switch (el.direction) {
                .row => total += child.box.w(),
                .column, .layer => total = @max(total, child.box.w() + pad_w),
                .grid => unreachable,
            }
            child_count += 1;
        }
        child_slot = child.next_sibling;
    }
    if (el.direction == .row and child_count > 1)
        total += el.gap * @as(f32, @floatFromInt(child_count - 1));
    return total;
}

fn fitHeight(self: *Context, slot: Element.Slot, el: *Element) f32 {
    if (el.intrinsic_h > 0)
        return el.intrinsic_h + el.padding.top() + el.padding.bottom();

    const pad_h = el.padding.top() + el.padding.bottom();

    if (el.direction == .grid) {
        const tpl = self.grid_templates.get(slot) orelse return pad_h;
        if (tpl.rows.len == 0) return pad_h;
        var sum: f32 = 0;
        for (tpl.rows) |t| switch (t) {
            .fixed => |v| sum += v,
            .fr => {},
        };
        if (tpl.rows.len > 1)
            sum += el.gap * @as(f32, @floatFromInt(tpl.rows.len - 1));
        return sum + pad_h;
    }

    var total = pad_h;
    var child_slot = el.first_child;
    var child_count: u32 = 0;
    while (child_slot != Element.INVALID_SLOT) {
        const child = self.pool.get(child_slot);
        if (child.position != .absolute) {
            switch (el.direction) {
                .column => total += child.box.h(),
                .row, .layer => total = @max(total, child.box.h() + pad_h),
                .grid => unreachable,
            }
            child_count += 1;
        }
        child_slot = child.next_sibling;
    }
    if (el.direction == .column and child_count > 1)
        total += el.gap * @as(f32, @floatFromInt(child_count - 1));
    return total;
}

pub const ScrollLookup = struct {
    ctx: *anyopaque,
    getFn: *const fn (ctx: *anyopaque, id: Element.Id) [2]f32,

    pub fn get(self: ScrollLookup, id: Element.Id) [2]f32 {
        return self.getFn(self.ctx, id);
    }
};

pub fn computeLayout(self: *Context, scroll: ScrollLookup, scrollbar_thickness: f32) LayoutError!void {
    try self.computeLayoutNode(self.root_slot, 0, 0, scroll, scrollbar_thickness);
    for (self.pool.elements.items, 0..) |*el, idx| {
        const slot: Element.Slot = @intCast(idx);
        if (slot != self.root_slot and el.parent == Element.INVALID_SLOT) {
            try self.computeLayoutNode(slot, el.box.x(), el.box.y(), scroll, scrollbar_thickness);
        }
    }
}

fn computeLayoutNode(self: *Context, root_slot: Element.Slot, x: f32, y: f32, scroll: ScrollLookup, scrollbar_thickness: f32) LayoutError!void {
    const el = self.pool.get(root_slot);

    el.box.setX(x);
    el.box.setY(y);
    el.content_w = el.box.w();
    el.content_h = el.box.h();

    switch (el.direction) {
        .grid => return self.computeGridLayout(root_slot, el, scroll, scrollbar_thickness),
        .layer => return self.computeLayerLayout(el, scroll, scrollbar_thickness),
        .row, .column => {},
    }

    const axis = AxisInfo.init(el);
    const static_count = countStaticChildren(self, el);
    resolvePercentChildren(self, el, axis, static_count);
    const m = self.measureChildren(el, axis);
    const gap = gapTotal(el, m.static_count);
    const avail = axis.available();
    const justify_free = @max(0, avail - (m.fixed_used - gap));
    const remaining_free = @max(0, avail - m.used);

    self.distributeGrow(el, axis, remaining_free, m.grow_count);
    try self.positionChildren(el, axis, m.fixed_used, justify_free, scroll, scrollbar_thickness);
}

fn computeLayerLayout(self: *Context, el: *Element, scroll: ScrollLookup, scrollbar_thickness: f32) LayoutError!void {
    const content_w = @max(0, el.box.w() - el.padding.left() - el.padding.right());
    const content_h = @max(0, el.box.h() - el.padding.top() - el.padding.bottom());
    const origin_x = el.box.x() + el.padding.left();
    const origin_y = el.box.y() + el.padding.top();

    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = self.pool.get(child_slot);
        if (child.position != .absolute) {
            if (child.width.kind == .grow)
                child.box.setW(std.math.clamp(content_w, child.width.min, child.width.max));
            if (child.width.kind == .percent)
                child.box.setW(std.math.clamp(child.width.value * content_w, child.width.min, child.width.max));
            if (child.height.kind == .grow)
                child.box.setH(std.math.clamp(content_h, child.height.min, child.height.max));
            if (child.height.kind == .percent)
                child.box.setH(std.math.clamp(child.height.value * content_h, child.height.min, child.height.max));

            const x_off: f32 = switch (el.justify) {
                .start, .space_between, .space_around => 0,
                .center => (content_w - child.box.w()) / 2,
                .end => content_w - child.box.w(),
            };
            const y_off: f32 = switch (el.alignment) {
                .start, .stretch => 0,
                .center => (content_h - child.box.h()) / 2,
                .end => content_h - child.box.h(),
            };
            child.box.setX(origin_x + x_off);
            child.box.setY(origin_y + y_off);

            try self.computeLayoutNode(child_slot, child.box.x(), child.box.y(), scroll, scrollbar_thickness);
        } else {
            if (child.width.kind == .grow) child.box.setW(content_w);
            if (child.width.kind == .percent) child.box.setW(std.math.clamp(child.width.value * content_w, child.width.min, child.width.max));
            if (child.height.kind == .grow) child.box.setH(content_h);
            if (child.height.kind == .percent) child.box.setH(std.math.clamp(child.height.value * content_h, child.height.min, child.height.max));
            try self.computeLayoutNode(child_slot, origin_x + child.offset[0], origin_y + child.offset[1], scroll, scrollbar_thickness);
        }
        child_slot = child.next_sibling;
    }
}

fn resolveGridTracks(tracks: []const Grid.Track, available: f32, gap: f32, sizes_out: []f32) void {
    if (tracks.len == 0) return;
    const gap_total = if (tracks.len > 1) gap * @as(f32, @floatFromInt(tracks.len - 1)) else 0;
    var fixed_total: f32 = 0;
    var fr_total: f32 = 0;
    for (tracks) |t| switch (t) {
        .fixed => |v| fixed_total += v,
        .fr => |v| fr_total += v,
    };
    const fr_pool = @max(0, available - fixed_total - gap_total);
    for (tracks, 0..) |t, i| {
        sizes_out[i] = switch (t) {
            .fixed => |v| v,
            .fr => |v| if (fr_total > 0) (v / fr_total) * fr_pool else 0,
        };
    }
}

const GRID_INLINE_TRACKS: usize = 32;

fn computeGridLayout(self: *Context, slot: Element.Slot, el: *Element, scroll: ScrollLookup, scrollbar_thickness: f32) LayoutError!void {
    const tpl = self.grid_templates.get(slot) orelse return;
    const cols = tpl.cols;
    const rows = tpl.rows;
    if (cols.len == 0 or rows.len == 0) return;

    const content_w = @max(0, el.box.w() - el.padding.left() - el.padding.right());
    const content_h = @max(0, el.box.h() - el.padding.top() - el.padding.bottom());

    var buf: [@sizeOf(f32) * GRID_INLINE_TRACKS * 4]u8 = undefined;
    var bfa = std.heap.BufferFirstAllocator.init(&buf, self.allocator);
    const allocator = bfa.allocator();

    const col_sizes = try allocator.alloc(f32, cols.len);
    defer allocator.free(col_sizes);

    const col_offsets = try allocator.alloc(f32, cols.len + 1);
    defer allocator.free(col_offsets);

    const row_sizes = try allocator.alloc(f32, rows.len);
    defer allocator.free(row_sizes);

    const row_offsets = try allocator.alloc(f32, rows.len + 1);
    defer allocator.free(row_offsets);

    resolveGridTracks(cols, content_w, el.gap, col_sizes);
    resolveGridTracks(rows, content_h, el.gap, row_sizes);

    col_offsets[0] = 0;
    for (col_sizes, 0..) |s, i| col_offsets[i + 1] = col_offsets[i] + s + el.gap;
    row_offsets[0] = 0;
    for (row_sizes, 0..) |s, i| row_offsets[i + 1] = row_offsets[i] + s + el.gap;

    const origin_x = el.box.x() + el.padding.left();
    const origin_y = el.box.y() + el.padding.top();
    const ncols: u32 = @intCast(cols.len);
    const nrows: u32 = @intCast(rows.len);

    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = self.pool.get(child_slot);
        if (child.position == .absolute) {
            child_slot = child.next_sibling;
            continue;
        }

        // Children without explicit placement default to (0, 0, 1, 1).
        const placement = self.grid_placements.get(child_slot) orelse Grid.Placement{};

        std.debug.assert(placement.col < ncols);
        std.debug.assert(placement.row < nrows);
        std.debug.assert(placement.col_span >= 1 and placement.col + placement.col_span <= ncols);
        std.debug.assert(placement.row_span >= 1 and placement.row + placement.row_span <= nrows);

        const c = placement.col;
        const r = placement.row;
        const cs = placement.col_span;
        const rs = placement.row_span;

        var w: f32 = 0;
        for (col_sizes[c .. c + cs]) |s| w += s;
        if (cs > 1) w += el.gap * @as(f32, @floatFromInt(cs - 1));
        var h: f32 = 0;
        for (row_sizes[r .. r + rs]) |s| h += s;
        if (rs > 1) h += el.gap * @as(f32, @floatFromInt(rs - 1));

        child.box.setX(origin_x + col_offsets[c]);
        child.box.setY(origin_y + row_offsets[r]);
        child.box.setW(std.math.clamp(w, child.width.min, child.width.max));
        child.box.setH(std.math.clamp(h, child.height.min, child.height.max));

        try self.computeLayoutNode(child_slot, child.box.x(), child.box.y(), scroll, scrollbar_thickness);
        child_slot = child.next_sibling;
    }

    child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = self.pool.get(child_slot);
        if (child.position == .absolute) {
            if (child.width.kind == .grow) child.box.setW(content_w);
            if (child.width.kind == .percent) child.box.setW(std.math.clamp(child.width.value * content_w, child.width.min, child.width.max));
            if (child.height.kind == .grow) child.box.setH(content_h);
            if (child.height.kind == .percent) child.box.setH(std.math.clamp(child.height.value * content_h, child.height.min, child.height.max));
            try self.computeLayoutNode(child_slot, origin_x + child.offset[0], origin_y + child.offset[1], scroll, scrollbar_thickness);
        }
        child_slot = child.next_sibling;
    }
}

fn gapTotal(el: *const Element, count: u32) f32 {
    return if (count > 1)
        el.gap * @as(f32, @floatFromInt(count - 1))
    else
        0;
}

fn countStaticChildren(self: *Context, el: *const Element) u32 {
    var count: u32 = 0;
    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = self.pool.get(child_slot);
        if (child.position != .absolute) count += 1;
        child_slot = child.next_sibling;
    }
    return count;
}

fn resolvePercentChildren(self: *Context, el: *const Element, axis: AxisInfo, static_count: u32) void {
    const main_base = @max(0, axis.available() - gapTotal(el, static_count));
    const cross_base = @max(0, axis.cross_size);

    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = self.pool.get(child_slot);
        if (child.position != .absolute) {
            if (axis.childMainKind(child) == .percent) {
                axis.setChildMainSize(
                    child,
                    std.math.clamp(axis.childMainPercent(child) * main_base, axis.childMainMin(child), axis.childMainMax(child)),
                );
            }
            if (axis.childCrossKind(child) == .percent) {
                axis.setChildCrossSize(
                    child,
                    std.math.clamp(axis.childCrossPercent(child) * cross_base, axis.childCrossMin(child), axis.childCrossMax(child)),
                );
            }
        }
        child_slot = child.next_sibling;
    }
}

fn measureChildren(self: *Context, el: *const Element, axis: AxisInfo) Measurement {
    var used: f32 = 0;
    var fixed_used: f32 = 0;
    var grow_count: f32 = 0;
    var static_count: u32 = 0;

    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = self.pool.get(child_slot);
        if (child.position != .absolute) {
            const main = axis.childMainSize(child);
            fixed_used += main;
            if (axis.childMainKind(child) == .grow) grow_count += 1 else used += main;
            static_count += 1;
        }
        child_slot = child.next_sibling;
    }

    const gap = gapTotal(el, static_count);
    used += gap;
    fixed_used += gap;

    return .{ .used = used, .fixed_used = fixed_used, .grow_count = grow_count, .static_count = static_count };
}

fn distributeGrow(self: *Context, el: *const Element, axis: AxisInfo, initial_free: f32, initial_grow_count: f32) void {
    var remaining_free = initial_free;
    var grow_count = initial_grow_count;

    while (grow_count > 0) {
        const grow_unit = remaining_free / grow_count;
        var clamped_space: f32 = 0;
        var still_growing: f32 = 0;

        var child_slot = el.first_child;
        while (child_slot != Element.INVALID_SLOT) {
            const child = self.pool.get(child_slot);
            if (child.position != .absolute and axis.childMainKind(child) == .grow) {
                const clamped = std.math.clamp(grow_unit, axis.childMainMin(child), axis.childMainMax(child));
                if (clamped != grow_unit) {
                    axis.setChildMainSize(child, clamped);
                    clamped_space += clamped;
                } else still_growing += 1;
            }
            child_slot = child.next_sibling;
        }

        if (still_growing == grow_count) break;

        remaining_free -= clamped_space;
        grow_count = still_growing;
    }

    const final_grow_unit = if (grow_count > 0) remaining_free / grow_count else 0;
    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = self.pool.get(child_slot);
        if (child.position != .absolute) {
            if (axis.childMainKind(child) == .grow and axis.childMainSize(child) == 0)
                axis.setChildMainSize(child, std.math.clamp(final_grow_unit, axis.childMainMin(child), axis.childMainMax(child)));
            if (axis.childCrossKind(child) == .grow)
                axis.setChildCrossSize(child, axis.cross_size);
        }
        child_slot = child.next_sibling;
    }
}

fn positionChildren(self: *Context, el: *Element, axis: AxisInfo, fixed_used: f32, justify_free: f32, scroll: ScrollLookup, scrollbar_thickness: f32) LayoutError!void {
    var static_count: u32 = 0;
    var children_main: f32 = 0;
    var children_cross: f32 = 0;
    {
        var cs = el.first_child;
        while (cs != Element.INVALID_SLOT) {
            const c = self.pool.get(cs);
            if (c.position != .absolute) {
                static_count += 1;
                children_main += axis.childMainSize(c);
                children_cross = @max(children_cross, axis.childCrossSize(c));
            }
            cs = c.next_sibling;
        }
    }

    var cursor: f32 = switch (el.justify) {
        .start, .space_between, .space_around => axis.pad_main_start,
        .end => axis.main_size - axis.pad_main_end - fixed_used,
        .center => axis.pad_main_start + justify_free / 2,
    };

    const item_gap: f32 = switch (el.justify) {
        .start, .end, .center => el.gap,
        .space_between => if (static_count > 1)
            justify_free / @as(f32, @floatFromInt(static_count - 1)) + el.gap
        else
            el.gap,
        .space_around => if (static_count > 0)
            justify_free / @as(f32, @floatFromInt(static_count)) + el.gap
        else
            el.gap,
    };

    const content_main = children_main + gapTotal(el, static_count) + axis.pad_main_start + axis.pad_main_end;
    const content_cross = children_cross + axis.pad_cross_start + axis.pad_cross_end;
    const content_w = if (axis.is_row) content_main else content_cross;
    const content_h = if (axis.is_row) content_cross else content_main;
    const metrics = Element.scrollMetrics(el.overflow, el.box, content_w, content_h, scrollbar_thickness);

    const scroll_offset: [2]f32 = if (el.overflow.isScroll()) blk: {
        const raw = scroll.get(el.id);
        break :blk switch (el.overflow) {
            .scroll_x => .{ std.math.clamp(raw[0], 0, metrics.max_offset[0]), 0 },
            .scroll_y => .{ 0, std.math.clamp(raw[1], 0, metrics.max_offset[1]) },
            .scroll => .{ std.math.clamp(raw[0], 0, metrics.max_offset[0]), std.math.clamp(raw[1], 0, metrics.max_offset[1]) },
            else => unreachable,
        };
    } else .{ 0, 0 };

    var child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = self.pool.get(child_slot);
        if (child.position == .absolute) {
            child_slot = child.next_sibling;
            continue;
        }
        const cross_offset = axis.pad_cross_start + switch (el.alignment) {
            .start, .stretch => @as(f32, 0),
            .center => (axis.cross_size - if (axis.is_row) child.box.h() else child.box.w()) / 2,
            .end => axis.cross_size - if (axis.is_row) child.box.h() else child.box.w(),
        };

        if (axis.is_row) {
            child.box.setX(el.box.x() + cursor - scroll_offset[0]);
            child.box.setY(el.box.y() + cross_offset - scroll_offset[1]);
        } else {
            child.box.setX(el.box.x() + cross_offset - scroll_offset[0]);
            child.box.setY(el.box.y() + cursor - scroll_offset[1]);
        }
        cursor += axis.childMainSize(child) + item_gap;

        try self.computeLayoutNode(child_slot, child.box.x(), child.box.y(), scroll, scrollbar_thickness);
        child_slot = child.next_sibling;
    }

    // Position absolute children: fill parent's content area and place at parent origin + padding + offset.
    child_slot = el.first_child;
    while (child_slot != Element.INVALID_SLOT) {
        const child = self.pool.get(child_slot);
        if (child.position == .absolute) {
            const abs_content_w = el.box.w() - el.padding.left() - el.padding.right();
            const abs_content_h = el.box.h() - el.padding.top() - el.padding.bottom();
            if (child.width.kind == .grow) child.box.setW(abs_content_w);
            if (child.width.kind == .percent) child.box.setW(std.math.clamp(child.width.value * abs_content_w, child.width.min, child.width.max));
            if (child.height.kind == .grow) child.box.setH(abs_content_h);
            if (child.height.kind == .percent) child.box.setH(std.math.clamp(child.height.value * abs_content_h, child.height.min, child.height.max));
            const cx = el.box.x() + el.padding.left() + child.offset[0];
            const cy = el.box.y() + el.padding.top() + child.offset[1];
            try self.computeLayoutNode(child_slot, cx, cy, scroll, scrollbar_thickness);
        }
        child_slot = child.next_sibling;
    }

    if (el.overflow.isScroll()) {
        if (axis.is_row) {
            el.content_w = content_main;
            el.content_h = content_cross;
        } else {
            el.content_w = content_cross;
            el.content_h = content_main;
        }
    }
}
