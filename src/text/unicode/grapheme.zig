const std = @import("std");
const unicode = @import("root.zig");

const GraphemeBreak = unicode.GraphemeBreak;

pub const State = struct {
    previous: ?unicode.Props = null,
    regional_odd: bool = false,
    emoji: Emoji = .none,
    conjunct: Conjunct = .none,

    const Emoji = enum { none, pictographic, joined };
    const Conjunct = enum { none, linked };

    /// Feeds the next codepoint and reports whether a grapheme boundary precedes it.
    pub fn push(state: *State, codepoint: u32) bool {
        const current = unicode.props(codepoint);
        const boundary = state.isBoundary(current);
        state.advance(current);
        return boundary;
    }

    fn isBoundary(state: *const State, current: unicode.Props) bool {
        const previous = state.previous orelse return true;
        const before = previous.grapheme_break;
        const after = current.grapheme_break;
        if (before == .cr and after == .lf) return false;
        if (isControl(before) or isControl(after)) return true;
        switch (before) {
            .l => switch (after) {
                .l, .v, .lv, .lvt => return false,
                else => {},
            },
            .lv, .v => switch (after) {
                .v, .t => return false,
                else => {},
            },
            .lvt, .t => if (after == .t) return false,
            else => {},
        }
        switch (after) {
            .extend, .zwj, .spacing_mark => return false,
            else => {},
        }
        if (before == .prepend) return false;
        if (state.conjunct == .linked and current.conjunct_break == .consonant) return false;
        if (state.emoji == .joined and current.extended_pictographic) return false;
        if (before == .regional_indicator and after == .regional_indicator) return !state.regional_odd;
        return true;
    }

    fn advance(state: *State, current: unicode.Props) void {
        state.previous = current;
        state.regional_odd = current.grapheme_break == .regional_indicator and !state.regional_odd;
        state.emoji = nextEmoji(state.emoji, current);
        state.conjunct = nextConjunct(state.conjunct, current);
    }

    fn nextEmoji(emoji: Emoji, current: unicode.Props) Emoji {
        if (current.extended_pictographic) return .pictographic;
        if (emoji != .pictographic) return .none;
        return switch (current.grapheme_break) {
            .extend => .pictographic,
            .zwj => .joined,
            else => .none,
        };
    }

    fn nextConjunct(conjunct: Conjunct, current: unicode.Props) Conjunct {
        return switch (current.conjunct_break) {
            .linker => .linked,
            .extend => conjunct,
            .consonant, .none => .none,
        };
    }
};

fn isControl(value: GraphemeBreak) bool {
    return switch (value) {
        .control, .cr, .lf => true,
        else => false,
    };
}

pub const Iterator = struct {
    text: []const u8,
    index: usize = 0,
    state: State = .{},
    pending: ?unicode.Decoded = null,

    pub fn init(text: []const u8) Iterator {
        return .{ .text = text };
    }

    /// Returns the end of the next grapheme.
    pub fn next(self: *Iterator) ?usize {
        if (self.index >= self.text.len) return null;
        var end = self.index;
        if (self.pending) |pending| {
            end += pending.len;
            self.pending = null;
        } else {
            const first = unicode.decodeUtf8(self.text, end);
            _ = self.state.push(first.codepoint);
            end += first.len;
        }
        while (end < self.text.len) {
            const decoded = unicode.decodeUtf8(self.text, end);
            if (self.state.push(decoded.codepoint)) {
                self.pending = decoded;
                break;
            }
            end += decoded.len;
        }
        self.index = end;
        return end;
    }
};

pub fn nextBoundary(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    var iterator = Iterator.init(text[pos..]);
    return pos + (iterator.next() orelse 0);
}

fn lineStart(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    const newline = std.mem.findScalarLast(u8, text[0 .. pos - 1], '\n') orelse return 0;
    return newline + 1;
}

pub fn previousBoundary(text: []const u8, pos: usize) usize {
    const end = @min(pos, text.len);
    if (end == 0) return 0;
    const start = lineStart(text, end);
    var iterator = Iterator.init(text[start..]);
    var previous = start;
    while (iterator.next()) |offset| {
        const boundary = start + offset;
        if (boundary >= end) return previous;
        previous = boundary;
    }
    return previous;
}

pub fn floorBoundary(text: []const u8, pos: usize) usize {
    const end = @min(pos, text.len);
    const start = lineStart(text, end);
    var iterator = Iterator.init(text[start..]);
    var floor = start;
    while (iterator.next()) |offset| {
        const boundary = start + offset;
        if (boundary > end) return floor;
        floor = boundary;
    }
    return floor;
}

pub fn isBoundary(text: []const u8, byte: usize) bool {
    if (byte == 0 or byte >= text.len) return true;
    var iterator = Iterator.init(text);
    while (iterator.next()) |end| {
        if (end == byte) return true;
        if (end > byte) return false;
    }
    return true;
}

pub fn count(text: []const u8) usize {
    var iterator = Iterator.init(text);
    var total: usize = 0;
    while (iterator.next()) |_| total += 1;
    return total;
}

test "steps over whole graphemes" {
    const text = "a\u{1F1FA}\u{1F1F8}e\u{0301}\nb";
    try std.testing.expectEqual(@as(usize, 1), nextBoundary(text, 0));
    try std.testing.expectEqual(@as(usize, 9), nextBoundary(text, 1));
    try std.testing.expectEqual(@as(usize, 1), previousBoundary(text, 9));
    try std.testing.expectEqual(@as(usize, 9), previousBoundary(text, 12));
    try std.testing.expectEqual(@as(usize, 13), previousBoundary(text, 14));
    try std.testing.expectEqual(@as(usize, 9), floorBoundary(text, 10));
    try std.testing.expectEqual(@as(usize, 1), floorBoundary(text, 5));
}

test "clusters emoji sequences, flags and combining marks" {
    try std.testing.expectEqual(@as(usize, 1), count("e\u{0301}"));
    try std.testing.expectEqual(@as(usize, 1), count("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"));
    try std.testing.expectEqual(@as(usize, 2), count("\u{1F1FA}\u{1F1F8}\u{1F1EB}\u{1F1F7}"));
    try std.testing.expectEqual(@as(usize, 1), count("\r\n"));
    try std.testing.expectEqual(@as(usize, 1), count("\u{0915}\u{094D}\u{0937}"));
    try std.testing.expectEqual(@as(usize, 3), count("\xff\xfea"));
    try std.testing.expectEqual(@as(usize, 0), count(""));
}
