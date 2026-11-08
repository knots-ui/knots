//! The window's copy of the focused field, which backends answer input method
//! queries from between frames. It edits through the same `text_edit.Field` as the UI.
const std = @import("std");
const input = @import("input");
const text_edit = @import("text_edit");

const Allocator = std.mem.Allocator;
const TextRange = input.TextRange;
const TextRect = input.TextRect;
const TextEdit = input.TextEdit;
const KeyEvent = input.KeyEvent;
const Session = input.TextInputSession;

active: bool = false,
id: u64 = 0,
purpose: input.TextInputPurpose = .text,
bytes_max: u32 = 0,
caret: TextRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
composition_rects: std.ArrayList(TextRect) = .empty,

buf: std.ArrayList(u8) = .empty,
edit_selection: text_edit.Selection = .{},
edit_composition: text_edit.Composition = .{},
owns_composition: bool = false,

/// The buffer with the composition in place.
text: std.ArrayList(u8) = .empty,
/// Changes whenever `text` does.
revision: u64 = 0,
/// `selection` and `composition` are bytes of `text`.
selection: TextRange = .at(0),
composition: ?TextRange = null,

const TextInputState = @This();

pub const Change = struct {
    /// Focus moved to a field: reset the input method.
    started: bool = false,
    ended: bool = false,
    /// The UI committed a composition the input method still holds.
    composition_dropped: bool = false,

    pub fn any(self: Change) bool {
        return self.started or self.ended or self.composition_dropped;
    }
};

pub fn deinit(self: *TextInputState, allocator: Allocator) void {
    self.composition_rects.deinit(allocator);
    self.buf.deinit(allocator);
    self.edit_composition.deinit(allocator);
    self.text.deinit(allocator);
}

pub fn set(self: *TextInputState, allocator: Allocator, session: ?*const Session) !Change {
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
    try self.composition_rects.resize(allocator, 0);
    try self.composition_rects.appendSlice(allocator, s.composition_rects);
    self.active = true;
    self.id = s.id;
    self.purpose = s.purpose;
    self.bytes_max = s.bytes_max;
    self.caret = s.caret;

    // Most frames publish the field the copy already holds.
    const same = !change.started and std.mem.eql(u8, self.text.items, s.text) and
        std.meta.eql(self.composition, s.composition) and std.meta.eql(self.selection, s.selection);
    if (same) return change;

    const doc = s.text;
    const len: u32 = @intCast(doc.len);
    const composition = if (s.composition) |c| clampRange(c, len) else null;
    const cut = composition orelse TextRange.at(len);
    try self.buf.resize(allocator, 0);
    try self.buf.appendSlice(allocator, doc[0..cut.start]);
    try self.buf.appendSlice(allocator, doc[cut.end..]);
    self.edit_composition.clear();
    self.owns_composition = composition != null;
    if (composition) |c| {
        const comp = &self.edit_composition;
        try comp.text.appendSlice(allocator, doc[c.start..c.end]);
        try comp.segments.appendSlice(allocator, s.composition_segments);
        comp.at = c.start;
        const sel = clampRange(s.selection, len);
        comp.caret = .{
            .start = std.math.clamp(sel.start, c.start, c.end) - c.start,
            .end = std.math.clamp(sel.end, c.start, c.end) - c.start,
        };
        comp.active = true;
        self.edit_selection = .at(c.start);
    } else {
        const sel = clampRange(s.selection, len);
        self.edit_selection = .{ .anchor = sel.start, .caret = sel.end };
    }
    try self.text.resize(allocator, 0);
    try self.text.appendSlice(allocator, doc);
    self.selection = s.selection;
    self.composition = composition;
    self.revision +%= 1;
    return change;
}

pub fn apply(self: *TextInputState, allocator: Allocator, edit: TextEdit) !void {
    var f = self.field(allocator);
    try f.apply(edit);
    try self.refresh(allocator, &f);
}

/// Keys that need layout change nothing until the next session.
pub fn applyKey(self: *TextInputState, allocator: Allocator, event: KeyEvent) !void {
    const command = text_edit.keyCommand(event, self.purpose == .multiline) orelse return;
    var f = self.field(allocator);
    try f.run(command);
    try self.refresh(allocator, &f);
}

pub fn target(self: *const TextInputState) TextRange {
    return self.composition orelse self.selection;
}

fn field(self: *TextInputState, allocator: Allocator) text_edit.Field {
    return .{
        .buf = &self.buf,
        .allocator = allocator,
        .selection = &self.edit_selection,
        .composition = &self.edit_composition,
        .composition_allocator = allocator,
        .owns_composition = self.owns_composition,
        .limits = .{ .multiline = self.purpose == .multiline, .bytes_max = self.bytes_max },
    };
}

fn refresh(self: *TextInputState, allocator: Allocator, f: *const text_edit.Field) !void {
    self.owns_composition = f.owns_composition;
    try f.writeText(allocator, &self.text);
    const v = f.view();
    self.selection = v.selection;
    self.composition = v.composition;
    self.revision +%= 1;
}

fn clampRange(r: TextRange, max: u32) TextRange {
    const end = @min(r.end, max);
    return .{ .start = @min(r.start, end), .end = end };
}

/// UTF-16 code units in `text[0..byte]`.
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

/// The composition's first line when `byte` is in it, else the caret.
pub fn rectFor(self: *const TextInputState, byte: u32) TextRect {
    if (self.composition) |c| {
        if (byte >= c.start and byte <= c.end and self.composition_rects.items.len > 0) {
            return self.composition_rects.items[0];
        }
    }
    return self.caret;
}

const testing = std.testing;

fn testSession(id: u64, doc: []const u8, selection: TextRange, composition: ?TextRange) Session {
    return .{
        .id = id,
        .text = doc,
        .selection = selection,
        .composition = composition,
        .purpose = .text,
        .bytes_max = 1024,
        .caret = .{ .x = 0, .y = 0, .w = 1, .h = 10 },
    };
}

test "edits and keys apply to the copy before the next frame" {
    var state: TextInputState = .{};
    defer state.deinit(testing.allocator);
    try testing.expect((try state.set(testing.allocator, &testSession(7, "ab", .at(1), null))).started);

    try state.apply(testing.allocator, .{ .text = "に", .compose = .{ .caret = .at(3) } });
    try testing.expectEqualStrings("aにb", state.text.items);
    try testing.expectEqual(TextRange{ .start = 1, .end = 4 }, state.composition.?);
    try testing.expectEqual(TextRange.at(4), state.selection);

    try state.apply(testing.allocator, .{ .text = "日" });
    try testing.expectEqualStrings("a日b", state.text.items);
    try testing.expectEqual(null, state.composition);
    try testing.expectEqual(TextRange.at(4), state.selection);

    // Editing keys change the copy too.
    try state.applyKey(testing.allocator, .{ .key = .backspace, .action = .press, .mods = .{} });
    try state.apply(testing.allocator, .{ .text = "x" });
    try testing.expectEqualStrings("axb", state.text.items);
}

test "a session in the middle of a composition splits the field" {
    var state: TextInputState = .{};
    defer state.deinit(testing.allocator);
    _ = try state.set(testing.allocator, &testSession(1, "aにb", .at(4), .{ .start = 1, .end = 4 }));
    try testing.expectEqualStrings("ab", state.buf.items);
    try testing.expectEqualStrings("に", state.edit_composition.text.items);

    const revision = state.revision;
    _ = try state.set(testing.allocator, &testSession(1, "aにb", .at(4), .{ .start = 1, .end = 4 }));
    try testing.expectEqual(revision, state.revision);

    try state.apply(testing.allocator, .{ .text = "日" });
    try testing.expectEqualStrings("a日b", state.text.items);
}

test "a new field restarts and a dropped composition is reported" {
    var state: TextInputState = .{};
    defer state.deinit(testing.allocator);
    var session = testSession(1, "x", .at(1), .{ .start = 0, .end = 1 });
    try testing.expect((try state.set(testing.allocator, &session)).started);
    session.composition = null;
    try testing.expect((try state.set(testing.allocator, &session)).composition_dropped);
    session.id = 2;
    try testing.expect((try state.set(testing.allocator, &session)).started);
    try testing.expect((try state.set(testing.allocator, null)).ended);
    try testing.expect(!(try state.set(testing.allocator, null)).any());
}

test "utf-16 offsets count surrogate pairs" {
    const doc = "a\u{1F600}é";
    try testing.expectEqual(@as(u32, 3), utf16Offset(doc, 5));
    try testing.expectEqual(@as(u32, 4), utf16Offset(doc, 7));
    try testing.expectEqual(@as(u32, 5), byteOffset(doc, 3));
    // Inside a surrogate pair rounds down.
    try testing.expectEqual(@as(u32, 1), byteOffset(doc, 2));
    try testing.expectEqual(@as(u32, 7), byteOffset(doc, 99));
}
