//! The text an input method is composing in the focused field.
//!
//! The composition never enters the app's buffer. It sits at byte `at` of the
//! buffer and is spliced in only for drawing and for the platform session, so
//! the app never sees uncommitted text. Platform edits address that spliced
//! text; `apply` maps them back onto the buffer.
const std = @import("std");
const input_types = @import("input");
const layout = @import("layout");
const Element = layout.Element;

const TextRange = input_types.TextRange;
const TextEdit = input_types.TextEdit;
const Segment = input_types.CompositionSegment;

/// The field composing, or `INVALID_ID`.
owner: Element.Id = Element.INVALID_ID,
/// Byte of the owner's buffer the composition sits at.
at: u32 = 0,
text: std.ArrayList(u8) = .empty,
/// Caret inside `text`.
caret: TextRange = .at(0),
segments: std.ArrayList(Segment) = .empty,

const Composition = @This();

pub fn deinit(self: *Composition, allocator: std.mem.Allocator) void {
    self.text.deinit(allocator);
    self.segments.deinit(allocator);
}

pub fn active(self: *const Composition, id: Element.Id) bool {
    return self.owner == id and self.owner != Element.INVALID_ID;
}

pub fn clear(self: *Composition) void {
    self.owner = Element.INVALID_ID;
    self.at = 0;
    self.text.clearRetainingCapacity();
    self.segments.clearRetainingCapacity();
    self.caret = .at(0);
}

/// Range of the composition in the spliced text.
pub fn range(self: *const Composition) TextRange {
    return .{ .start = self.at, .end = self.at + @as(u32, @intCast(self.text.items.len)) };
}

/// `buf` with the composition of `id` in place.
pub fn splice(self: *const Composition, arena: std.mem.Allocator, id: Element.Id, buf: []const u8) ![]u8 {
    if (!self.active(id)) return arena.dupe(u8, buf);
    const at = @min(self.at, buf.len);
    return std.mem.concat(arena, u8, &.{ buf[0..at], self.text.items, buf[at..] });
}

/// Commits the composition of `id` into `buf` as typed text.
pub fn commit(self: *Composition, allocator: std.mem.Allocator, id: Element.Id, buf: *std.ArrayList(u8), bytes_max: u32) !?u32 {
    if (!self.active(id)) return null;
    defer self.clear();
    const at = @min(self.at, @as(u32, @intCast(buf.items.len)));
    if (buf.items.len + self.text.items.len > bytes_max) return at;
    try buf.insertSlice(allocator, at, self.text.items);
    return at + @as(u32, @intCast(self.text.items.len));
}

pub const Applied = struct {
    /// Selection in the buffer, anchor first.
    anchor: u32,
    cursor: u32,
};

/// Applies one platform edit to field `id`, whose buffer is `buf`. Returns the
/// new buffer selection, or null when the edit does not fit the field and is
/// dropped. A commit that does not fit still ends the composition: the platform
/// already considers it gone.
pub fn apply(
    self: *Composition,
    allocator: std.mem.Allocator,
    id: Element.Id,
    buf: *std.ArrayList(u8),
    edit: TextEdit,
    multiline: bool,
    bytes_max: u32,
) !?Applied {
    const owned = self.active(id);
    const buf_len: u32 = @intCast(buf.items.len);
    const at: u32 = if (owned) @min(self.at, buf_len) else 0;
    const composed: []const u8 = if (owned) self.text.items else &.{};
    const doc: Doc = .{ .buf = buf.items, .at = at, .composed = composed };
    const doc_len = doc.len();
    const r = edit.replace;
    if (r.start > r.end or r.end > doc_len) return null;
    if (!doc.isBoundary(r.start) or !doc.isBoundary(r.end)) return null;
    if (!std.unicode.utf8ValidateSlice(edit.text)) return null;
    const text_len: u32 = @intCast(edit.text.len);

    // The buffer is everything outside the composition.
    const committed_len = doc_len - r.len() + (if (edit.compose == null) text_len else 0);
    if (committed_len > bytes_max) {
        if (edit.compose != null or !owned) return null;
        self.clear();
        return .{ .anchor = at, .cursor = at };
    }

    // Reserve everything first so a failed allocation leaves the field as it was.
    try buf.ensureTotalCapacity(allocator, @max(doc_len, committed_len));
    if (edit.compose) |compose| {
        try self.text.ensureTotalCapacity(allocator, text_len);
        try self.segments.ensureTotalCapacity(allocator, compose.segments.len);
    }

    // Composition text outside the replaced range is committed with the edit.
    if (owned) {
        // Read the text again: reserving its capacity may have moved it.
        buf.replaceRangeAssumeCapacity(at, 0, self.text.items);
        self.clear();
    }
    const inserted = if (edit.compose == null) edit.text else "";
    buf.replaceRangeAssumeCapacity(r.start, r.len(), inserted);

    if (edit.compose) |compose| {
        if (text_len == 0) return .{ .anchor = r.start, .cursor = r.start };
        // Another field's composition, if any, is replaced.
        self.clear();
        self.text.appendSliceAssumeCapacity(edit.text);
        if (!multiline) singleLine(self.text.items);
        for (compose.segments) |segment| {
            if (segment.start >= segment.end or segment.end > text_len) continue;
            self.segments.appendAssumeCapacity(segment);
        }
        self.owner = id;
        self.at = r.start;
        self.caret = clampRange(compose.caret, text_len);
        return .{ .anchor = r.start, .cursor = r.start };
    }

    if (!multiline) singleLine(buf.items[r.start..][0..text_len]);
    const end = r.start + text_len;
    const selection = if (edit.selection) |s| clampRange(s, @intCast(buf.items.len)) else TextRange.at(end);
    return .{
        .anchor = floorBoundary(buf.items, selection.start),
        .cursor = floorBoundary(buf.items, selection.end),
    };
}

/// The field's text with a composition in place, without building it.
const Doc = struct {
    buf: []const u8,
    at: u32,
    composed: []const u8,

    fn len(self: Doc) u32 {
        return @intCast(self.buf.len + self.composed.len);
    }

    fn byte(self: Doc, i: u32) u8 {
        const n: u32 = @intCast(self.composed.len);
        if (i < self.at) return self.buf[i];
        if (i < self.at + n) return self.composed[i - self.at];
        return self.buf[i - n];
    }

    fn isBoundary(self: Doc, i: u32) bool {
        return i == self.len() or (i < self.len() and (self.byte(i) & 0xC0) != 0x80);
    }
};

fn singleLine(text: []u8) void {
    for (text) |*ch| {
        if (ch.* == '\n' or ch.* == '\r') ch.* = ' ';
    }
}

fn clampRange(r: TextRange, max: u32) TextRange {
    const end = @min(r.end, max);
    return .{ .start = @min(r.start, end), .end = end };
}

fn isBoundary(text: []const u8, byte: u32) bool {
    return byte == text.len or (byte < text.len and (text[byte] & 0xC0) != 0x80);
}

fn floorBoundary(text: []const u8, byte: u32) u32 {
    var b = @min(byte, @as(u32, @intCast(text.len)));
    while (b > 0 and !isBoundary(text, b)) b -= 1;
    return b;
}

const testing = std.testing;

fn applyTest(c: *Composition, buf: *std.ArrayList(u8), edit: TextEdit) !?Applied {
    return c.apply(testing.allocator, 1, buf, edit, false, 1024);
}

test "a composition never enters the buffer until it is committed" {
    var c: Composition = .{};
    defer c.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "ab");

    // Compose "に" at byte 1.
    _ = try applyTest(&c, &buf, .{ .session = 1, .replace = .at(1), .text = "に", .compose = .{ .caret = .at(3) } });
    try testing.expectEqualStrings("ab", buf.items);
    try testing.expectEqualStrings("に", c.text.items);
    try testing.expectEqual(@as(u32, 1), c.at);

    // The input method replaces its composition with a longer one.
    _ = try applyTest(&c, &buf, .{ .session = 1, .replace = c.range(), .text = "にほ", .compose = .{ .caret = .at(6) } });
    try testing.expectEqualStrings("ab", buf.items);
    try testing.expectEqualStrings("にほ", c.text.items);

    // Commit the converted text over the composition.
    const applied = (try applyTest(&c, &buf, .{ .session = 1, .replace = c.range(), .text = "日本" })).?;
    try testing.expectEqualStrings("a日本b", buf.items);
    try testing.expect(!c.active(1));
    try testing.expectEqual(@as(u32, 7), applied.cursor);
}

test "an empty composition cancels it" {
    var c: Composition = .{};
    defer c.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "ab");

    _ = try applyTest(&c, &buf, .{ .session = 1, .replace = .at(2), .text = "´", .compose = .{ .caret = .at(2) } });
    try testing.expect(c.active(1));
    _ = try applyTest(&c, &buf, .{ .session = 1, .replace = c.range(), .text = "", .compose = .{ .caret = .at(0) } });
    try testing.expect(!c.active(1));
    try testing.expectEqualStrings("ab", buf.items);
}

test "a replacement range rewrites committed text" {
    // Press and hold `e`, then pick `é`: the accent replaces the typed `e`.
    var c: Composition = .{};
    defer c.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "cafe");

    const applied = (try applyTest(&c, &buf, .{ .session = 1, .replace = .{ .start = 3, .end = 4 }, .text = "é" })).?;
    try testing.expectEqualStrings("café", buf.items);
    try testing.expectEqual(@as(u32, 5), applied.cursor);
}

test "edits outside the text, inside a code point, or over the limit are dropped" {
    var c: Composition = .{};
    defer c.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "é");

    try testing.expectEqual(null, try applyTest(&c, &buf, .{ .session = 1, .replace = .at(3), .text = "x" }));
    try testing.expectEqual(null, try applyTest(&c, &buf, .{ .session = 1, .replace = .at(1), .text = "x" }));
    try testing.expectEqual(null, try applyTest(&c, &buf, .{ .session = 1, .replace = .at(0), .text = "\xff" }));

    try testing.expectEqual(null, try c.apply(testing.allocator, 1, &buf, .{ .session = 1, .replace = .at(0), .text = "x" }, false, 2));
    try testing.expectEqualStrings("é", buf.items);
}

test "single-line fields turn committed line breaks into spaces" {
    var c: Composition = .{};
    defer c.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    _ = try applyTest(&c, &buf, .{ .session = 1, .replace = .at(0), .text = "a\nb" });
    try testing.expectEqualStrings("a b", buf.items);
}

test "committing on focus loss inserts the composition at its position" {
    var c: Composition = .{};
    defer c.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "ab");

    _ = try applyTest(&c, &buf, .{ .session = 1, .replace = .at(1), .text = "x", .compose = .{ .caret = .at(1) } });
    try testing.expectEqual(@as(?u32, 2), try c.commit(testing.allocator, 1, &buf, 1024));
    try testing.expectEqualStrings("axb", buf.items);
    try testing.expect(!c.active(1));
}

test "a commit over the byte limit ends the composition" {
    var c: Composition = .{};
    defer c.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "ab");

    _ = try c.apply(testing.allocator, 1, &buf, .{ .session = 1, .replace = .at(1), .text = "にほ", .compose = .{ .caret = .at(6) } }, false, 4);
    try testing.expect(c.active(1));
    const applied = (try c.apply(testing.allocator, 1, &buf, .{ .session = 1, .replace = c.range(), .text = "日本" }, false, 4)).?;
    try testing.expect(!c.active(1));
    try testing.expectEqualStrings("ab", buf.items);
    try testing.expectEqual(@as(u32, 1), applied.cursor);
}

test "a commit to one field keeps another field's composition" {
    var c: Composition = .{};
    defer c.deinit(testing.allocator);
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(testing.allocator);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(testing.allocator);

    _ = try c.apply(testing.allocator, 1, &a, .{ .session = 1, .replace = .at(0), .text = "´", .compose = .{ .caret = .at(2) } }, false, 1024);
    _ = try c.apply(testing.allocator, 2, &b, .{ .session = 1, .replace = .at(0), .text = "x" }, false, 1024);
    try testing.expectEqualStrings("x", b.items);
    try testing.expect(c.active(1));
    try testing.expectEqual(@as(?u32, 2), try c.commit(testing.allocator, 1, &a, 1024));
    try testing.expectEqualStrings("´", a.items);
}

test "a composition in a single-line field turns line breaks into spaces" {
    var c: Composition = .{};
    defer c.deinit(testing.allocator);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    _ = try applyTest(&c, &buf, .{ .session = 1, .replace = .at(0), .text = "a\nb", .compose = .{ .caret = .at(3) } });
    try testing.expectEqualStrings("a b", c.text.items);
    _ = try applyTest(&c, &buf, .{ .session = 1, .replace = .{ .start = 0, .end = 1 }, .text = "z" });
    try testing.expectEqualStrings("z b", buf.items);
}
