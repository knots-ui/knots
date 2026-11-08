//! Keys and text in order. Their text lives in buffers the queue reuses, so steady
//! input allocates nothing; entries hold offsets until `resolve`.
const std = @import("std");
const input = @import("input");

const Allocator = std.mem.Allocator;
const Event = input.Event;
const KeyEvent = input.KeyEvent;
const TextEdit = input.TextEdit;
const Segment = input.CompositionSegment;

entries: std.ArrayList(Entry) = .empty,
bytes: std.ArrayList(u8) = .empty,
segments: std.ArrayList(Segment) = .empty,
/// Valid until the next `clear`.
events: std.ArrayList(Event) = .empty,

const EventQueue = @This();

const Span = struct { start: u32, len: u32 };

const Entry = union(enum) {
    key: KeyEvent,
    /// `edit.text` and segments are empty; the spans locate them.
    text: struct { edit: TextEdit, text: Span, segments: Span },
};

pub fn deinit(self: *EventQueue, allocator: Allocator) void {
    self.entries.deinit(allocator);
    self.bytes.deinit(allocator);
    self.segments.deinit(allocator);
    self.events.deinit(allocator);
}

pub fn clear(self: *EventQueue) void {
    self.entries.clearRetainingCapacity();
    self.bytes.clearRetainingCapacity();
    self.segments.clearRetainingCapacity();
    self.events.clearRetainingCapacity();
}

pub fn len(self: *const EventQueue) usize {
    return self.entries.items.len;
}

pub fn pushKey(self: *EventQueue, allocator: Allocator, event: KeyEvent) !void {
    try self.entries.append(allocator, .{ .key = event });
}

pub fn pushText(self: *EventQueue, allocator: Allocator, edit: TextEdit) !void {
    const segments: []const Segment = if (edit.compose) |compose| compose.segments else &.{};
    try self.entries.ensureUnusedCapacity(allocator, 1);
    try self.bytes.ensureUnusedCapacity(allocator, edit.text.len);
    try self.segments.ensureUnusedCapacity(allocator, segments.len);

    const text: Span = .{ .start = @intCast(self.bytes.items.len), .len = @intCast(edit.text.len) };
    const segment_span: Span = .{ .start = @intCast(self.segments.items.len), .len = @intCast(segments.len) };
    self.bytes.appendSliceAssumeCapacity(edit.text);
    self.segments.appendSliceAssumeCapacity(segments);
    var stored = edit;
    stored.text = &.{};
    if (stored.compose) |*compose| compose.segments = &.{};
    self.entries.appendAssumeCapacity(.{ .text = .{ .edit = stored, .text = text, .segments = segment_span } });
}

/// Nothing may be pushed while the events are in use: their text would move.
pub fn resolve(self: *EventQueue, allocator: Allocator) ![]const Event {
    try self.events.resize(allocator, self.entries.items.len);
    for (self.entries.items, self.events.items) |entry, *event| event.* = switch (entry) {
        .key => |key| .{ .key = key },
        .text => |t| blk: {
            var edit = t.edit;
            edit.text = self.bytes.items[t.text.start..][0..t.text.len];
            if (edit.compose) |*compose| compose.segments = self.segments.items[t.segments.start..][0..t.segments.len];
            break :blk .{ .text = edit };
        },
    };
    return self.events.items;
}

test "events keep their order and their text" {
    const testing = std.testing;
    var queue: EventQueue = .{};
    defer queue.deinit(testing.allocator);

    const segments = [_]Segment{.{ .start = 0, .end = 3, .active = true }};
    try queue.pushKey(testing.allocator, .{ .key = .left, .action = .press, .mods = .{} });
    var text = "に".*;
    try queue.pushText(testing.allocator, .{ .text = &text, .compose = .{ .caret = .at(3), .segments = &segments } });
    // The caller's text may change once it is queued.
    text = "xxx".*;
    try queue.pushText(testing.allocator, .{ .text = "a" });

    const events = try queue.resolve(testing.allocator);
    try testing.expectEqual(@as(usize, 3), events.len);
    try testing.expectEqual(input.Key.left, events[0].key.key);
    try testing.expectEqualStrings("に", events[1].text.text);
    try testing.expectEqual(@as(usize, 1), events[1].text.compose.?.segments.len);
    try testing.expectEqualStrings("a", events[2].text.text);

    queue.clear();
    try testing.expectEqual(@as(usize, 0), (try queue.resolve(testing.allocator)).len);
}
