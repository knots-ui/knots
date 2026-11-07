//! The window's copy of the focused field's `TextInputSession`.
//!
//! Input methods query the field synchronously, between frames, so backends
//! answer from this copy. Each edit a backend sends is applied here at once,
//! so the input method's next query sees it before the UI does; the next
//! frame's session then replaces the copy.
const std = @import("std");
const input = @import("input");

const TextRange = input.TextRange;
const TextRect = input.TextRect;
const TextEdit = input.TextEdit;
const Session = input.TextInputSession;
const Segment = input.CompositionSegment;

active: bool = false,
id: u64 = 0,
text: std.ArrayList(u8) = .empty,
/// Changes whenever `text` does, so backends can tell a new text without comparing it.
revision: u64 = 0,
selection: TextRange = .at(0),
composition: ?TextRange = null,
segments: std.ArrayList(Segment) = .empty,
purpose: input.TextInputPurpose = .text,
caret: TextRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
composition_rects: std.ArrayList(TextRect) = .empty,

const TextInputState = @This();

/// What a new session changes, for the backend to tell the input method.
pub const Change = struct {
    /// A field gained focus, or focus moved to another field: reset the input method.
    started: bool = false,
    /// No field has focus any more.
    ended: bool = false,
    /// The UI dropped a composition the input method still has (a click committed it).
    composition_dropped: bool = false,

    pub fn any(self: Change) bool {
        return self.started or self.ended or self.composition_dropped;
    }
};

pub fn deinit(self: *TextInputState, allocator: std.mem.Allocator) void {
    self.text.deinit(allocator);
    self.segments.deinit(allocator);
    self.composition_rects.deinit(allocator);
}

pub fn set(self: *TextInputState, allocator: std.mem.Allocator, session: ?*const Session) !Change {
    const s = session orelse {
        defer self.active = false;
        return .{ .ended = self.active };
    };
    var change: Change = .{};
    if (!self.active or self.id != s.id) {
        change.started = true;
    } else if (self.composition != null and s.composition == null) {
        change.composition_dropped = true;
    }
    // Most frames publish the text the copy already holds.
    if (change.started or !std.mem.eql(u8, self.text.items, s.text)) {
        try self.text.resize(allocator, 0);
        try self.text.appendSlice(allocator, s.text);
        self.revision +%= 1;
    }
    try self.segments.resize(allocator, 0);
    try self.segments.appendSlice(allocator, s.composition_segments);
    try self.composition_rects.resize(allocator, 0);
    try self.composition_rects.appendSlice(allocator, s.composition_rects);
    self.active = true;
    self.id = s.id;
    self.selection = s.selection;
    self.composition = s.composition;
    self.purpose = s.purpose;
    self.caret = s.caret;
    return change;
}

/// Applies `edit` the way the UI will, so later queries see its result.
pub fn apply(self: *TextInputState, allocator: std.mem.Allocator, edit: TextEdit) !void {
    const len: u32 = @intCast(self.text.items.len);
    const r: TextRange = .{ .start = @min(edit.replace.start, len), .end = @min(edit.replace.end, len) };
    if (r.start > r.end) return;
    try self.text.replaceRange(allocator, r.start, r.len(), edit.text);
    self.revision +%= 1;
    const text_len: u32 = @intCast(edit.text.len);
    try self.segments.resize(allocator, 0);
    if (edit.compose) |compose| {
        if (text_len == 0) {
            self.composition = null;
            self.selection = .at(r.start);
            return;
        }
        self.composition = .{ .start = r.start, .end = r.start + text_len };
        try self.segments.appendSlice(allocator, compose.segments);
        self.selection = .{
            .start = r.start + @min(compose.caret.start, text_len),
            .end = r.start + @min(compose.caret.end, text_len),
        };
    } else {
        self.composition = null;
        self.selection = edit.selection orelse .at(r.start + text_len);
    }
}

/// The range the input method writes to when it names none: the composition, else the selection.
pub fn target(self: *const TextInputState) TextRange {
    return self.composition orelse self.selection;
}

/// UTF-16 code units in `text[0..byte]`, for macOS, Windows and the browser.
pub fn utf16Offset(text: []const u8, byte: u32) u32 {
    var units: u32 = 0;
    var i: usize = 0;
    const end = @min(byte, text.len);
    while (i < end) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        units += if (n == 4) 2 else 1;
        i += n;
    }
    return units;
}

/// The byte where `units` UTF-16 code units of `text` end, rounded down to a code point.
pub fn byteOffset(text: []const u8, units: u32) u32 {
    var counted: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const w: u32 = if (n == 4) 2 else 1;
        if (counted + w > units) break;
        counted += w;
        i += n;
    }
    return @intCast(@min(i, text.len));
}

pub fn utf16Range(text: []const u8, r: TextRange) TextRange {
    return .{ .start = utf16Offset(text, r.start), .end = utf16Offset(text, r.end) };
}

pub fn byteRange(text: []const u8, r: TextRange) TextRange {
    return .{ .start = byteOffset(text, r.start), .end = byteOffset(text, r.end) };
}

/// The rectangle covering byte `byte`: a composition line when it falls inside one, else the caret.
pub fn rectFor(self: *const TextInputState, byte: u32) TextRect {
    if (self.composition) |c| {
        if (byte >= c.start and byte <= c.end and self.composition_rects.items.len > 0) {
            return self.composition_rects.items[0];
        }
    }
    return self.caret;
}

const testing = std.testing;

test "edits apply to the copy before the next frame" {
    var state: TextInputState = .{};
    defer state.deinit(testing.allocator);
    const change = try state.set(testing.allocator, &.{
        .id = 7,
        .text = "ab",
        .selection = .at(1),
        .composition = null,
        .purpose = .text,
        .caret = .{ .x = 0, .y = 0, .w = 1, .h = 10 },
    });
    try testing.expect(change.started);
    const revision = state.revision;
    _ = try state.set(testing.allocator, &.{
        .id = 7,
        .text = "ab",
        .selection = .at(2),
        .composition = null,
        .purpose = .text,
        .caret = .{ .x = 0, .y = 0, .w = 1, .h = 10 },
    });
    try testing.expectEqual(revision, state.revision);
    try testing.expectEqual(TextRange.at(2), state.selection);
    state.selection = .at(1);

    try state.apply(testing.allocator, .{ .session = 7, .replace = state.target(), .text = "に", .compose = .{ .caret = .at(3) } });
    try testing.expectEqualStrings("aにb", state.text.items);
    try testing.expectEqual(TextRange{ .start = 1, .end = 4 }, state.composition.?);
    try testing.expectEqual(TextRange.at(4), state.selection);

    try state.apply(testing.allocator, .{ .session = 7, .replace = state.target(), .text = "日" });
    try testing.expectEqualStrings("a日b", state.text.items);
    try testing.expectEqual(null, state.composition);
    try testing.expectEqual(TextRange.at(4), state.selection);
}

test "a new field restarts and a dropped composition is reported" {
    var state: TextInputState = .{};
    defer state.deinit(testing.allocator);
    var session: Session = .{
        .id = 1,
        .text = "x",
        .selection = .at(1),
        .composition = .{ .start = 0, .end = 1 },
        .purpose = .text,
        .caret = .{ .x = 0, .y = 0, .w = 1, .h = 10 },
    };
    try testing.expect((try state.set(testing.allocator, &session)).started);
    session.composition = null;
    try testing.expect((try state.set(testing.allocator, &session)).composition_dropped);
    session.id = 2;
    try testing.expect((try state.set(testing.allocator, &session)).started);
    try testing.expect((try state.set(testing.allocator, null)).ended);
    try testing.expect(!(try state.set(testing.allocator, null)).any());
}

test "utf-16 offsets count surrogate pairs" {
    const text = "a\u{1F600}é";
    try testing.expectEqual(@as(u32, 3), utf16Offset(text, 5));
    try testing.expectEqual(@as(u32, 4), utf16Offset(text, 7));
    try testing.expectEqual(@as(u32, 5), byteOffset(text, 3));
    // Inside a surrogate pair rounds down.
    try testing.expectEqual(@as(u32, 1), byteOffset(text, 2));
    try testing.expectEqual(@as(u32, 7), byteOffset(text, 99));
}
