const std = @import("std");
const Element = @import("layout").Element;
const animation = @import("animation.zig");

pub const TextInput = struct {
    cursor: u32 = 0,
    sel_anchor: u32 = 0,
    scroll_x: f32 = 0,
};

pub const TextSelect = struct {
    anchor_byte: u32 = 0,
    cursor_byte: u32 = 0,
    dragging: bool = false,
    box: Element.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

pub const Scroll = struct {
    offset: [2]f32 = .{ 0, 0 },
};

pub const SelectInput = struct {
    open: bool = false,
    selected: ?u32 = null,
    anchor_box: Element.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    viewport_box: Element.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

pub const Slider = struct {
    bounds: Element.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

pub const Measured = struct {
    width: f32 = 0,
    height: f32 = 0,
};

pub const Anim = struct {
    current: f32 = 0,
    start_value: f32 = 0,
    target: f32 = 0,
    t0_ms: i64 = 0,
    duration_ms: u32 = 0,
    ease: animation.Ease = .smooth_step,
    initialized: bool = false,
};

// Element.Id is the Wyhash output of a Key (see Key.hash), so it is
// well-distributed and identity-hashing is correct here.
const IdContext = struct {
    pub fn hash(_: IdContext, id: Element.Id) u64 {
        return id;
    }
    pub fn eql(_: IdContext, a: Element.Id, b: Element.Id) bool {
        return a == b;
    }
};

pub const DEFAULT_TTL_FRAMES: u32 = 60;

/// Hash map of (id, T) pairs with TTL-based eviction.
///
/// Each entry stamps `last_seen` on creation and on every `getOrCreate` touch.
/// `endFrame` evicts entries whose stamp is older than `ttl` frames.
///
/// Lifetime: with `ttl=N`, an entry survives N `endFrame` calls without a
/// touch and is evicted on the (N+1)th. So `ttl=1` keeps an entry for one
/// frame past its last touch, then drops it.
fn Pool(comptime T: type) type {
    return struct {
        pub const Value = T;

        const Entry = struct {
            value: T,
            last_seen: u32,
        };
        const Map = std.HashMapUnmanaged(Element.Id, Entry, IdContext, std.hash_map.default_max_load_percentage);

        map: Map = .empty,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.map.deinit(allocator);
        }

        pub fn get(self: *Self, id: Element.Id) ?*T {
            if (self.map.getPtr(id)) |e| return &e.value;
            return null;
        }

        pub fn getOrCreate(self: *Self, allocator: std.mem.Allocator, id: Element.Id, frame: u32) !*T {
            const gop = try self.map.getOrPutContext(allocator, id, .{});
            if (!gop.found_existing) gop.value_ptr.* = .{ .value = .{}, .last_seen = frame } else gop.value_ptr.last_seen = frame;
            return &gop.value_ptr.value;
        }

        pub fn remove(self: *Self, id: Element.Id) void {
            _ = self.map.remove(id);
        }

        pub fn evictStale(self: *Self, allocator: std.mem.Allocator, frame: u32, ttl: u32, scratch: *std.ArrayList(Element.Id)) !void {
            scratch.clearRetainingCapacity();
            var it = self.map.iterator();
            while (it.next()) |kv| {
                if (frame -% kv.value_ptr.last_seen >= ttl) {
                    try scratch.append(allocator, kv.key_ptr.*);
                }
            }
            for (scratch.items) |id| _ = self.map.remove(id);
        }
    };
}

fn PoolValueType(comptime PoolT: type) type {
    return PoolT.Value;
}

pub const Storage = struct {
    const StoragePools = struct {
        text_input: Pool(TextInput) = .{},
        text_select: Pool(TextSelect) = .{},
        scroll: Pool(Scroll) = .{},
        select_input: Pool(SelectInput) = .{},
        slider: Pool(Slider) = .{},
        measured: Pool(Measured) = .{},
        anim: Pool(Anim) = .{},
    };

    pools: StoragePools = .{},

    inline fn poolFor(self: *Storage, comptime name: std.meta.FieldEnum(StoragePools)) *@FieldType(StoragePools, @tagName(name)) {
        return &@field(self.pools, @tagName(name));
    }

    pub fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        inline for (std.meta.fields(StoragePools)) |f| {
            @field(self.pools, f.name).deinit(allocator);
        }
    }

    pub fn get(self: *Storage, comptime name: std.meta.FieldEnum(StoragePools), id: Element.Id) ?*PoolValueType(@FieldType(StoragePools, @tagName(name))) {
        return self.poolFor(name).get(id);
    }

    pub fn getOrCreate(self: *Storage, comptime name: std.meta.FieldEnum(StoragePools), allocator: std.mem.Allocator, id: Element.Id, frame: u32) !*PoolValueType(@FieldType(StoragePools, @tagName(name))) {
        return self.poolFor(name).getOrCreate(allocator, id, frame);
    }

    pub fn remove(self: *Storage, comptime name: std.meta.FieldEnum(StoragePools), id: Element.Id) void {
        self.poolFor(name).remove(id);
    }

    pub fn evictStale(self: *Storage, allocator: std.mem.Allocator, frame: u32, ttl: u32, scratch: *std.ArrayList(Element.Id)) !void {
        inline for (std.meta.fields(StoragePools)) |f| {
            try @field(self.pools, f.name).evictStale(allocator, frame, ttl, scratch);
        }
    }

    pub fn forEach(
        self: *Storage,
        comptime name: std.meta.FieldEnum(StoragePools),
        ctx: anytype,
        comptime f: fn (@TypeOf(ctx), Element.Id, *PoolValueType(@FieldType(StoragePools, @tagName(name)))) void,
    ) void {
        const pool = self.poolFor(name);
        var it = pool.map.iterator();
        while (it.next()) |kv| f(ctx, kv.key_ptr.*, &kv.value_ptr.value);
    }
};

allocator: std.mem.Allocator,
hovered: Element.Id = Element.INVALID_ID,
active: Element.Id = Element.INVALID_ID,
focused: Element.Id = Element.INVALID_ID,
press_origin: Element.Id = Element.INVALID_ID,
press_pos: [2]f64 = .{ 0, 0 },
press_drag: bool = false,
storage: Storage = .{},
frame: u32 = 0,
ttl: u32 = DEFAULT_TTL_FRAMES,
evict_scratch: std.ArrayList(Element.Id) = .empty,

const State = @This();

pub fn init(allocator: std.mem.Allocator, ttl: u32) State {
    return .{
        .allocator = allocator,
        .ttl = ttl,
    };
}

pub fn deinit(self: *State) void {
    self.evict_scratch.deinit(self.allocator);
    self.storage.deinit(self.allocator);
}

/// Returns a pointer to the state for `id`, or null if not yet created.
/// Does not refresh the TTL stamp.
pub fn get(self: *State, comptime name: @EnumLiteral(), id: Element.Id) ?*PoolValueType(@FieldType(Storage.StoragePools, @tagName(name))) {
    return self.storage.get(name, id);
}

/// Returns a pointer to the state for `id`, creating a default-initialised
/// entry if it does not exist yet. Refreshes the TTL stamp on every call.
pub fn getOrCreate(self: *State, comptime name: @EnumLiteral(), allocator: std.mem.Allocator, id: Element.Id) !*PoolValueType(@FieldType(Storage.StoragePools, @tagName(name))) {
    return self.storage.getOrCreate(name, allocator, id, self.frame);
}

pub fn remove(self: *State, comptime name: @EnumLiteral(), id: Element.Id) void {
    self.storage.remove(name, id);
}

pub fn forEach(
    self: *State,
    comptime name: @EnumLiteral(),
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), Element.Id, *PoolValueType(@FieldType(Storage.StoragePools, @tagName(name)))) void,
) void {
    self.storage.forEach(name, ctx, f);
}

/// Call at the end of each frame. Evicts entries whose `last_seen` stamp is
/// older than `ttl` frames, then advances the frame counter.
///
/// Order matters: the sweep uses `self.frame` as "this frame's stamp," so
/// any entry touched this frame has `last_seen == self.frame` and survives.
/// We advance only after the sweep so the next frame's stamp is one greater.
pub fn endFrame(self: *State) !void {
    try self.storage.evictStale(self.allocator, self.frame, self.ttl, &self.evict_scratch);
    self.frame +%= 1;
}

pub fn getScroll(self: *State, id: Element.Id) [2]f32 {
    const s = self.storage.getOrCreate(.scroll, self.allocator, id, self.frame) catch return .{ 0, 0 };
    return s.offset;
}

pub fn addScroll(self: *State, id: Element.Id, el: *const Element, delta: [2]f32) !void {
    const max_x = @max(0, el.content_w - el.box.w);
    const max_y = @max(0, el.content_h - el.box.h);
    const s = try self.storage.getOrCreate(.scroll, self.allocator, id, self.frame);
    s.offset[0] = std.math.clamp(s.offset[0] + delta[0], 0, max_x);
    s.offset[1] = std.math.clamp(s.offset[1] + delta[1], 0, max_y);
}

const testing = std.testing;

test "getOrCreate returns default state" {
    var state = init(testing.allocator, DEFAULT_TTL_FRAMES);
    defer state.deinit();

    const s = try state.getOrCreate(.text_input, testing.allocator, 42);
    try testing.expectEqual(s.cursor, 0);
    try testing.expectEqual(s.sel_anchor, 0);
    try testing.expectEqual(s.scroll_x, 0);
}

test "get returns null before creation" {
    var state = init(testing.allocator, DEFAULT_TTL_FRAMES);
    defer state.deinit();

    try testing.expectEqual(state.get(.text_input, 42), null);
}

test "getOrCreate is idempotent" {
    var state = init(testing.allocator, DEFAULT_TTL_FRAMES);
    defer state.deinit();

    const a = try state.getOrCreate(.text_input, testing.allocator, 42);
    a.cursor = 7;

    const b = try state.getOrCreate(.text_input, testing.allocator, 42);
    try testing.expectEqual(b.cursor, 7);
}

test "separate ids are independent" {
    var state = init(testing.allocator, DEFAULT_TTL_FRAMES);
    defer state.deinit();

    const a = try state.getOrCreate(.text_input, testing.allocator, 1);
    const b = try state.getOrCreate(.text_input, testing.allocator, 2);
    a.cursor = 3;
    b.cursor = 9;

    try testing.expectEqual((try state.getOrCreate(.text_input, testing.allocator, 1)).cursor, 3);
    try testing.expectEqual((try state.getOrCreate(.text_input, testing.allocator, 2)).cursor, 9);
}

test "ttl=1: untouched entry evicted after one endFrame, touched entry survives" {
    var state = init(testing.allocator, 1);
    defer state.deinit();

    _ = try state.getOrCreate(.text_input, testing.allocator, 1);
    _ = try state.getOrCreate(.text_input, testing.allocator, 2);

    try state.endFrame();

    _ = try state.getOrCreate(.text_input, testing.allocator, 1);
    try state.endFrame();

    try testing.expectEqual(state.get(.text_input, 2), null);
    try testing.expect(state.get(.text_input, 1) != null);
}

test "endFrame preserves mutated values across frames" {
    var state = init(testing.allocator, DEFAULT_TTL_FRAMES);
    defer state.deinit();

    const s = try state.getOrCreate(.text_input, testing.allocator, 99);
    s.cursor = 5;

    try state.endFrame();

    const after = try state.getOrCreate(.text_input, testing.allocator, 99);
    try testing.expectEqual(after.cursor, 5);
}

test "state survives ttl skipped frames" {
    // ttl=N: entry stays alive for N endFrame calls without a touch, and is
    // evicted on the (N+1)th.
    var state = init(testing.allocator, 5);
    defer state.deinit();

    const s = try state.getOrCreate(.text_input, testing.allocator, 1);
    s.cursor = 42;

    var i: u32 = 0;
    while (i < 5) : (i += 1) try state.endFrame();
    try testing.expect(state.get(.text_input, 1) != null);
    try testing.expectEqual(state.get(.text_input, 1).?.cursor, 42);

    try state.endFrame();
    try testing.expectEqual(state.get(.text_input, 1), null);
}

test "re-touching resets the eviction clock" {
    var state = init(testing.allocator, 3);
    defer state.deinit();

    _ = try state.getOrCreate(.text_input, testing.allocator, 1);

    try state.endFrame(); // skipped
    try state.endFrame(); // skipped

    _ = try state.getOrCreate(.text_input, testing.allocator, 1);

    try state.endFrame();
    try state.endFrame();
    try testing.expect(state.get(.text_input, 1) != null);
}

test "remove deletes entry" {
    var state = init(testing.allocator, DEFAULT_TTL_FRAMES);
    defer state.deinit();

    _ = try state.getOrCreate(.text_input, testing.allocator, 10);
    state.remove(.text_input, 10);
    try testing.expectEqual(state.get(.text_input, 10), null);
}

test "forEach visits each id once" {
    var state = init(testing.allocator, DEFAULT_TTL_FRAMES);
    defer state.deinit();

    _ = try state.getOrCreate(.text_input, testing.allocator, 1);
    _ = try state.getOrCreate(.text_input, testing.allocator, 2);
    try state.endFrame();
    _ = try state.getOrCreate(.text_input, testing.allocator, 1);

    const Counter = struct {
        seen: *std.AutoHashMap(Element.Id, u32),
        fn cb(self: @This(), id: Element.Id, _: *TextInput) void {
            const gop = self.seen.getOrPut(id) catch return;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    };

    var seen: std.AutoHashMap(Element.Id, u32) = .init(testing.allocator);
    defer seen.deinit();
    state.forEach(.text_input, Counter{ .seen = &seen }, Counter.cb);

    try testing.expectEqual(@as(?u32, 1), seen.get(1));
    try testing.expectEqual(@as(?u32, 1), seen.get(2));
}

test "pools are independent per type" {
    var state = init(testing.allocator, DEFAULT_TTL_FRAMES);
    defer state.deinit();

    const t = try state.getOrCreate(.text_input, testing.allocator, 1);
    const s = try state.getOrCreate(.scroll, testing.allocator, 1);

    t.cursor = 42;
    s.offset = .{ 100, 200 };

    try testing.expectEqual(state.get(.text_input, 1).?.cursor, 42);
    try testing.expectEqual(state.get(.scroll, 1).?.offset[0], 100);
}
