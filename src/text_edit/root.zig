//! Text field editing, shared by the UI and the window's copy of the focused field.
//! The composition never enters the buffer; it is spliced in where the text is shown.
//! `TextEdit` and `View` ranges are bytes of that spliced text, `Selection` of the buffer.
const std = @import("std");
const input = @import("input");
const unicode = @import("unicode");

const grapheme = unicode.grapheme;
const Allocator = std.mem.Allocator;
const TextRange = input.TextRange;
const TextEdit = input.TextEdit;
const KeyEvent = input.KeyEvent;
const Segment = input.CompositionSegment;

/// Bytes of the buffer; `caret` is the end that moves.
pub const Selection = struct {
    anchor: u32 = 0,
    caret: u32 = 0,

    pub fn at(byte: u32) Selection {
        return .{ .anchor = byte, .caret = byte };
    }

    pub fn range(self: Selection) TextRange {
        return .{ .start = @min(self.anchor, self.caret), .end = @max(self.anchor, self.caret) };
    }

    pub fn isEmpty(self: Selection) bool {
        return self.anchor == self.caret;
    }
};

/// One per window: the platform composes into one field at a time.
pub const Composition = struct {
    active: bool = false,
    /// Byte of the buffer.
    at: u32 = 0,
    text: std.ArrayList(u8) = .empty,
    /// Caret inside `text`.
    caret: TextRange = .at(0),
    /// Clauses, in bytes of `text`.
    segments: std.ArrayList(Segment) = .empty,

    pub fn deinit(self: *Composition, allocator: Allocator) void {
        self.text.deinit(allocator);
        self.segments.deinit(allocator);
    }

    pub fn clear(self: *Composition) void {
        self.active = false;
        self.at = 0;
        self.text.clearRetainingCapacity();
        self.segments.clearRetainingCapacity();
        self.caret = .at(0);
    }

    pub fn range(self: *const Composition) TextRange {
        return .{ .start = self.at, .end = self.at + @as(u32, @intCast(self.text.items.len)) };
    }
};

pub const Limits = struct {
    multiline: bool,
    /// The composition does not count.
    bytes_max: u32,
};

pub const Command = union(enum) {
    delete_backward,
    delete_forward,
    move: Move,
    /// For movement that needs layout.
    move_to: struct { byte: u32, extend: bool = false },
    select_all,
    delete_selection,
    insert: []const u8,

    pub const Move = struct {
        forward: bool,
        unit: Unit = .grapheme,
        extend: bool = false,
    };

    pub const Unit = enum { grapheme, word, all };
};

/// Null when the key does not edit, or needs layout (vertical, and multiline home and end).
pub fn keyCommand(event: KeyEvent, multiline: bool) ?Command {
    if (event.action == .release) return null;
    const chord = input.clipboardModifierHeld(event.mods);
    const extend = event.mods.shift;
    return switch (event.key) {
        .backspace => .delete_backward,
        .delete => .delete_forward,
        .left, .right => .{ .move = .{
            .forward = event.key == .right,
            .unit = if (event.mods.alt) .word else .grapheme,
            .extend = extend,
        } },
        .home, .end => if (multiline) null else .{ .move = .{ .forward = event.key == .end, .unit = .all, .extend = extend } },
        .a => if (chord) .select_all else null,
        .x => if (chord) .delete_selection else null,
        .enter => if (multiline) .{ .insert = "\n" } else null,
        else => null,
    };
}

pub const View = struct {
    selection: TextRange,
    /// The composition's caret while composing.
    caret: u32,
    composition: ?TextRange,
};

pub const Field = struct {
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    selection: *Selection,
    composition: *Composition,
    composition_allocator: Allocator,
    /// A field that does not own the composition sees none, until a composing edit.
    owns_composition: bool,
    limits: Limits,

    pub fn composing(self: *const Field) bool {
        return self.owns_composition and self.composition.active;
    }

    pub fn textLen(self: *const Field) u32 {
        return self.splice().len();
    }

    pub fn target(self: *const Field) TextRange {
        if (self.composing()) return self.composition.range();
        return self.selection.range();
    }

    pub fn view(self: *const Field) View {
        if (self.composing()) {
            const c = self.composition;
            const caret = c.at + c.caret.end;
            return .{
                .selection = .{ .start = c.at + c.caret.start, .end = caret },
                .caret = caret,
                .composition = c.range(),
            };
        }
        return .{ .selection = self.selection.range(), .caret = self.selection.caret, .composition = null };
    }

    pub fn writeText(self: *const Field, allocator: Allocator, out: *std.ArrayList(u8)) !void {
        const s = self.splice();
        try out.ensureTotalCapacity(allocator, s.len());
        out.clearRetainingCapacity();
        out.appendSliceAssumeCapacity(s.before);
        out.appendSliceAssumeCapacity(s.composed);
        out.appendSliceAssumeCapacity(s.after);
    }

    pub fn text(self: *const Field, allocator: Allocator) ![]u8 {
        const s = self.splice();
        return std.mem.concat(allocator, u8, &.{ s.before, s.composed, s.after });
    }

    /// Drops edits that do not fit or name an invalid range, but a commit that does
    /// not fit still ends the composition. `edit.text` must not point into the composition.
    pub fn apply(self: *Field, edit: TextEdit) !void {
        const s = self.splice();
        const doc_len = s.len();
        const r = edit.replace orelse self.target();
        if (r.start > r.end or r.end > doc_len) return;
        if (!s.isBoundary(r.start) or !s.isBoundary(r.end)) return;
        if (!std.unicode.utf8ValidateSlice(edit.text)) return;
        const text_len: u32 = @intCast(edit.text.len);
        const composing_before = self.composing();

        const committed_len = doc_len - r.len() + (if (edit.compose == null) text_len else 0);
        if (committed_len > self.limits.bytes_max) {
            if (edit.compose == null and composing_before) {
                self.selection.* = .at(self.composition.at);
                self.endComposition();
            }
            return;
        }

        // Reserve first, so a failed allocation leaves the field as it was.
        try self.buf.ensureTotalCapacity(self.allocator, @max(doc_len, committed_len));
        if (edit.compose) |compose| {
            try self.composition.text.ensureTotalCapacity(self.composition_allocator, text_len);
            try self.composition.segments.ensureTotalCapacity(self.composition_allocator, compose.segments.len);
        }

        // Composition text outside the replaced range is committed with the edit.
        if (composing_before) {
            self.buf.replaceRangeAssumeCapacity(self.composition.at, 0, self.composition.text.items);
            self.endComposition();
        }
        const inserted = if (edit.compose == null) edit.text else "";
        self.buf.replaceRangeAssumeCapacity(r.start, r.len(), inserted);

        if (edit.compose) |compose| {
            self.selection.* = .at(r.start);
            if (text_len == 0) return;
            const c = self.composition;
            c.clear();
            c.text.appendSliceAssumeCapacity(edit.text);
            if (!self.limits.multiline) singleLine(c.text.items);
            for (compose.segments) |segment| {
                if (segment.start >= segment.end or segment.end > text_len) continue;
                c.segments.appendAssumeCapacity(segment);
            }
            c.at = r.start;
            c.caret = clampRange(compose.caret, text_len);
            c.active = true;
            self.owns_composition = true;
            return;
        }

        if (!self.limits.multiline) singleLine(self.buf.items[r.start..][0..text_len]);
        const buf_len: u32 = @intCast(self.buf.items.len);
        const selection = if (edit.selection) |sel| clampRange(sel, buf_len) else TextRange.at(r.start + text_len);
        self.selection.* = .{
            .anchor = floorCodePoint(self.buf.items, selection.start),
            .caret = floorCodePoint(self.buf.items, selection.end),
        };
    }

    pub fn commitComposition(self: *Field) !void {
        if (!self.composing()) return;
        const c = self.composition;
        const at: u32 = @min(c.at, @as(u32, @intCast(self.buf.items.len)));
        const committed: u32 = @intCast(c.text.items.len);
        if (self.buf.items.len + committed <= self.limits.bytes_max) {
            try self.buf.insertSlice(self.allocator, at, c.text.items);
            self.selection.* = .at(at + committed);
        } else {
            self.selection.* = .at(at);
        }
        self.endComposition();
    }

    pub fn run(self: *Field, command: Command) !void {
        // Only hosts that bypass the input method send keys while composing.
        try self.commitComposition();
        const buf = self.buf.items;
        const len: u32 = @intCast(buf.len);
        const sel = self.selection;
        sel.anchor = @min(sel.anchor, len);
        sel.caret = @min(sel.caret, len);
        switch (command) {
            .delete_backward => {
                if (sel.isEmpty()) {
                    if (sel.caret == 0) return;
                    sel.anchor = previousGrapheme(buf, sel.caret);
                }
                self.deleteSelection();
            },
            .delete_forward => {
                if (sel.isEmpty()) {
                    if (sel.caret == len) return;
                    sel.anchor = nextGrapheme(buf, sel.caret);
                }
                self.deleteSelection();
            },
            .move => |move| {
                const r = sel.range();
                if (!move.extend and !sel.isEmpty() and move.unit != .all) {
                    sel.* = .at(if (move.forward) r.end else r.start);
                    return;
                }
                sel.caret = switch (move.unit) {
                    .grapheme => if (move.forward) nextGrapheme(buf, sel.caret) else previousGrapheme(buf, sel.caret),
                    .word => wordBoundary(buf, sel.caret, move.forward),
                    .all => if (move.forward) len else 0,
                };
                if (!move.extend) sel.anchor = sel.caret;
            },
            .move_to => |to| {
                sel.caret = floorGrapheme(buf, to.byte);
                if (!to.extend) sel.anchor = sel.caret;
            },
            .select_all => sel.* = .{ .anchor = 0, .caret = len },
            .delete_selection => self.deleteSelection(),
            .insert => |inserted| try self.apply(.{ .text = inserted }),
        }
    }

    fn deleteSelection(self: *Field) void {
        const r = self.selection.range();
        self.buf.replaceRangeAssumeCapacity(r.start, r.len(), &.{});
        self.selection.* = .at(r.start);
    }

    fn endComposition(self: *Field) void {
        self.composition.clear();
        self.owns_composition = false;
    }

    fn splice(self: *const Field) Splice {
        const buf = self.buf.items;
        if (!self.composing()) return .{ .before = buf, .composed = &.{}, .after = &.{} };
        const at = @min(self.composition.at, buf.len);
        return .{ .before = buf[0..at], .composed = self.composition.text.items, .after = buf[at..] };
    }
};

const Splice = struct {
    before: []const u8,
    composed: []const u8,
    after: []const u8,

    fn len(self: Splice) u32 {
        return @intCast(self.before.len + self.composed.len + self.after.len);
    }

    fn byte(self: Splice, i: usize) u8 {
        if (i < self.before.len) return self.before[i];
        const j = i - self.before.len;
        if (j < self.composed.len) return self.composed[j];
        return self.after[j - self.composed.len];
    }

    fn isBoundary(self: Splice, i: u32) bool {
        return i == self.len() or (i < self.len() and (self.byte(i) & 0xC0) != 0x80);
    }
};

pub fn previousGrapheme(text: []const u8, byte: u32) u32 {
    return @intCast(grapheme.previousBoundary(text, byte));
}

pub fn nextGrapheme(text: []const u8, byte: u32) u32 {
    return @intCast(grapheme.nextBoundary(text, byte));
}

pub fn floorGrapheme(text: []const u8, byte: u32) u32 {
    return @intCast(grapheme.floorBoundary(text, byte));
}

pub fn isWordByte(text: []const u8, byte: u32) bool {
    if (byte >= text.len) return false;
    const b = text[byte];
    return b == '_' or std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// Past any separators, then to the end of the word.
pub fn wordBoundary(text: []const u8, byte: u32, forward: bool) u32 {
    const len: u32 = @intCast(text.len);
    var i = byte;
    var in_word = false;
    while ((!forward and i > 0) or (forward and i < len)) {
        const char = if (forward) i else previousGrapheme(text, i);
        const word = isWordByte(text, char);
        if (in_word and !word) break;
        in_word = in_word or word;
        i = if (forward) nextGrapheme(text, i) else char;
    }
    return i;
}

/// Empty at `byte` when it is not in a word.
pub fn wordAt(text: []const u8, byte: u32) TextRange {
    const len: u32 = @intCast(text.len);
    var pos = floorGrapheme(text, byte);
    if (pos == len and pos > 0) pos = previousGrapheme(text, pos);
    if (!isWordByte(text, pos)) return .at(pos);
    var start = pos;
    while (start > 0) {
        const prev = previousGrapheme(text, start);
        if (!isWordByte(text, prev)) break;
        start = prev;
    }
    var end = nextGrapheme(text, pos);
    while (end < len and isWordByte(text, end)) end = nextGrapheme(text, end);
    return .{ .start = start, .end = end };
}

fn singleLine(text: []u8) void {
    for (text) |*ch| {
        if (ch.* == '\n' or ch.* == '\r') ch.* = ' ';
    }
}

fn clampRange(r: TextRange, max: u32) TextRange {
    const end = @min(r.end, max);
    return .{ .start = @min(r.start, end), .end = end };
}

fn floorCodePoint(text: []const u8, byte: u32) u32 {
    var b = @min(byte, @as(u32, @intCast(text.len)));
    while (b > 0 and b < text.len and (text[b] & 0xC0) == 0x80) b -= 1;
    return b;
}

const testing = std.testing;

const TestField = struct {
    buf: std.ArrayList(u8) = .empty,
    selection: Selection = .{},
    composition: Composition = .{},
    owns: bool = true,
    limits: Limits = .{ .multiline = false, .bytes_max = 1024 },

    fn init(text_: []const u8) !TestField {
        var t: TestField = .{};
        try t.buf.appendSlice(testing.allocator, text_);
        t.selection = .at(@intCast(text_.len));
        return t;
    }

    fn deinit(self: *TestField) void {
        self.buf.deinit(testing.allocator);
        self.composition.deinit(testing.allocator);
    }

    fn field(self: *TestField) Field {
        return .{
            .buf = &self.buf,
            .allocator = testing.allocator,
            .selection = &self.selection,
            .composition = &self.composition,
            .composition_allocator = testing.allocator,
            .owns_composition = self.owns,
            .limits = self.limits,
        };
    }

    fn apply(self: *TestField, edit: TextEdit) !void {
        var f = self.field();
        try f.apply(edit);
        self.owns = f.owns_composition;
    }

    fn run(self: *TestField, command: Command) !void {
        var f = self.field();
        try f.run(command);
        self.owns = f.owns_composition;
    }
};

test "a composition stays out of the buffer until it is committed" {
    var t = try TestField.init("ab");
    defer t.deinit();
    t.selection = .at(1);

    try t.apply(.{ .text = "に", .compose = .{ .caret = .at(3) } });
    try testing.expectEqualStrings("ab", t.buf.items);
    var f = t.field();
    try testing.expectEqual(TextRange{ .start = 1, .end = 4 }, f.view().composition.?);
    try testing.expectEqual(@as(u32, 4), f.view().caret);

    try t.apply(.{ .text = "にほ", .compose = .{ .caret = .at(6) } });
    try testing.expectEqualStrings("ab", t.buf.items);
    try testing.expectEqualStrings("にほ", t.composition.text.items);

    try t.apply(.{ .text = "日本" });
    try testing.expectEqualStrings("a日本b", t.buf.items);
    try testing.expect(!t.owns);
    try testing.expectEqual(Selection.at(7), t.selection);
}

test "an empty composition cancels it" {
    var t = try TestField.init("ab");
    defer t.deinit();
    try t.apply(.{ .text = "´", .compose = .{ .caret = .at(2) } });
    try testing.expect(t.owns);
    try t.apply(.{ .text = "", .compose = .{ .caret = .at(0) } });
    try testing.expect(!t.composition.active);
    try testing.expectEqualStrings("ab", t.buf.items);
}

test "a replacement range rewrites committed text" {
    // Press and hold `e`, then pick `é`: the accent replaces the typed `e`.
    var t = try TestField.init("cafe");
    defer t.deinit();
    try t.apply(.{ .replace = .{ .start = 3, .end = 4 }, .text = "é" });
    try testing.expectEqualStrings("café", t.buf.items);
    try testing.expectEqual(Selection.at(5), t.selection);
}

test "edits outside the text, inside a code point, or over the limit are dropped" {
    var t = try TestField.init("é");
    defer t.deinit();
    try t.apply(.{ .replace = .at(3), .text = "x" });
    try t.apply(.{ .replace = .at(1), .text = "x" });
    try t.apply(.{ .replace = .at(0), .text = "\xff" });
    t.limits.bytes_max = 2;
    try t.apply(.{ .replace = .at(0), .text = "x" });
    try testing.expectEqualStrings("é", t.buf.items);
}

test "a commit over the byte limit ends the composition" {
    var t = try TestField.init("ab");
    defer t.deinit();
    t.limits.bytes_max = 4;
    t.selection = .at(1);
    try t.apply(.{ .text = "にほ", .compose = .{ .caret = .at(6) } });
    try testing.expect(t.owns);
    try t.apply(.{ .text = "日本" });
    try testing.expect(!t.composition.active);
    try testing.expectEqualStrings("ab", t.buf.items);
    try testing.expectEqual(Selection.at(1), t.selection);
}

test "a field that does not own the composition leaves it alone" {
    var a = try TestField.init("");
    defer a.deinit();
    try a.apply(.{ .text = "´", .compose = .{ .caret = .at(2) } });

    var b: TestField = .{ .owns = false };
    defer b.buf.deinit(testing.allocator);
    var f: Field = .{
        .buf = &b.buf,
        .allocator = testing.allocator,
        .selection = &b.selection,
        .composition = &a.composition,
        .composition_allocator = testing.allocator,
        .owns_composition = false,
        .limits = b.limits,
    };
    try f.apply(.{ .text = "x" });
    try testing.expectEqualStrings("x", b.buf.items);
    try testing.expect(a.composition.active);

    try a.run(.select_all);
    try testing.expectEqualStrings("´", a.buf.items);
}

test "single-line fields turn line breaks into spaces" {
    var t = try TestField.init("");
    defer t.deinit();
    try t.apply(.{ .text = "a\nb", .compose = .{ .caret = .at(3) } });
    try testing.expectEqualStrings("a b", t.composition.text.items);
    try t.apply(.{ .text = "c\r\nd" });
    try testing.expectEqualStrings("c  d", t.buf.items);
}

test "editing keys run the same commands everywhere" {
    var t = try TestField.init("ab cd");
    defer t.deinit();
    t.limits.multiline = true;
    const press = struct {
        fn key(k: input.Key, mods: input.Mods) KeyEvent {
            return .{ .key = k, .action = .press, .mods = mods };
        }
    };

    try t.run(keyCommand(press.key(.left, .{ .alt = true }), true).?);
    try testing.expectEqual(Selection.at(3), t.selection);
    try t.run(keyCommand(press.key(.backspace, .{}), true).?);
    try testing.expectEqualStrings("abcd", t.buf.items);
    try t.run(keyCommand(press.key(.enter, .{}), true).?);
    try testing.expectEqualStrings("ab\ncd", t.buf.items);
    try t.run(keyCommand(press.key(.right, .{ .shift = true }), true).?);
    try testing.expectEqual(Selection{ .anchor = 3, .caret = 4 }, t.selection);
    try t.run(keyCommand(press.key(.delete, .{}), true).?);
    try testing.expectEqualStrings("ab\nd", t.buf.items);

    try testing.expectEqual(null, keyCommand(press.key(.home, .{}), true));
    try testing.expectEqual(null, keyCommand(press.key(.enter, .{}), false));
    try testing.expectEqual(null, keyCommand(.{ .key = .backspace, .action = .release, .mods = .{} }, true));
}

test "a key while composing commits the composition first" {
    var t = try TestField.init("a");
    defer t.deinit();
    try t.apply(.{ .text = "´", .compose = .{ .caret = .at(2) } });
    try t.run(.delete_backward);
    try testing.expectEqualStrings("a", t.buf.items);
    try testing.expect(!t.composition.active);
}

test "movement steps over graphemes and words" {
    const value = "a\u{1F44D}\u{1F3FD}e\u{0301}";
    try testing.expectEqual(@as(u32, 9), nextGrapheme(value, 1));
    try testing.expectEqual(@as(u32, 1), previousGrapheme(value, 9));
    try testing.expectEqual(@as(u32, 9), floorGrapheme(value, 10));
    try testing.expectEqual(TextRange{ .start = 4, .end = 7 }, wordAt("one two three", 5));
    try testing.expectEqual(@as(u32, 7), wordBoundary("one two three", 4, true));
    try testing.expectEqual(@as(u32, 4), wordBoundary("one two three", 7, false));
}
