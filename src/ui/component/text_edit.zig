const std = @import("std");

const Frame = @import("../root.zig").Frame;
const input_types = @import("input");
const UI = @import("../root.zig").UI;
const State = @import("../root.zig").State;
const Element = @import("layout").Element;
const TextLayout = @import("text").TextLayout;
const grapheme = @import("text").unicode.grapheme;
const Accessibility = @import("../Accessibility.zig");
const decoration = @import("../decoration.zig");
const Decoration = decoration.Decoration;
const text_edit = @import("text_edit");
const TextRange = input_types.TextRange;
const TextRect = input_types.TextRect;

const DOUBLE_CLICK_MS: i64 = 400;

pub const text_bytes_max: u32 = 1024 * 1024;

pub const Feature = @import("text").shape.Plan.Feature;

/// Turns contextual alternates off around the caret, so ligatures break apart where the user is editing.
pub fn caretFeatures(buf: []const u8, cursor: u32, out: *[1]Feature) []const Feature {
    var start: u32 = @intCast(grapheme.previousBoundary(buf, cursor));
    var end: u32 = @intCast(grapheme.nextBoundary(buf, cursor));
    while (start > 0 and isOperator(buf[start - 1])) start -= 1;
    while (end < buf.len and isOperator(buf[end])) end += 1;
    if (start == end) return &.{};
    out[0] = .{ .tag = std.mem.readInt(u32, "calt", .big), .value = 0, .start = start, .end = end };
    return out[0..1];
}

fn isOperator(byte: u8) bool {
    return std.ascii.isPrint(byte) and !std.ascii.isAlphanumeric(byte) and byte != ' ' and byte != '_';
}

/// Layout of an edited buffer, keyed by its element so edits reshape only the paragraphs they touch.
pub fn editLayout(ui: *UI, key: u64, buf: []const u8, size: f32, font: ?[]const u8, wrap_width: f32, features: []const Feature) !*const TextLayout {
    return ui.styledTextLayout(&.{ .content = buf, .size = size, .font = font, .features = features, .key = key }, wrap_width);
}

pub fn processAccessibility(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, frame: *Frame, state: *State.TextInput, id: Element.Id, bytes_max: u32) !void {
    const ui = frame.ui();
    if (ui.consumeAccessibilityAction(id, .set_value)) |request| {
        if (request.value_text) |value| {
            if (value.len <= bytes_max) {
                try buf.replaceRange(allocator, 0, buf.items.len, value);
                state.selection = .at(@intCast(value.len));
            }
        }
    }
    if (ui.consumeAccessibilityAction(id, .set_text_selection)) |request| {
        if (request.selection_anchor) |anchor| {
            if (request.selection_focus) |focus| {
                state.selection = .{ .anchor = characterToByte(buf.items, anchor), .caret = characterToByte(buf.items, focus) };
            }
        }
    }
    if (ui.consumeAccessibilityAction(id, .replace_selected_text)) |request| {
        if (request.value_text) |value| {
            const selection = state.selection.range();
            const final_len = buf.items.len - selection.len() + value.len;
            if (final_len <= bytes_max) {
                try buf.replaceRange(allocator, selection.start, selection.len(), value);
                state.selection = .at(selection.start + @as(u32, @intCast(value.len)));
            }
        }
    }
}

pub const Limits = text_edit.Limits;

pub fn field(ui: *UI, id: Element.Id, buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: *State.TextInput, limits: Limits) text_edit.Field {
    return .{
        .buf = buf,
        .allocator = allocator,
        .selection = &s.selection,
        .composition = &ui.composition,
        .composition_allocator = ui.allocator,
        .owns_composition = ui.composition_owner == id,
        .limits = limits,
    };
}

/// Records whether the field owns the composition after an edit.
pub fn settle(ui: *UI, id: Element.Id, f: *const text_edit.Field) void {
    if (f.owns_composition) {
        ui.composition_owner = id;
    } else if (ui.composition_owner == id) {
        ui.composition_owner = Element.INVALID_ID;
    }
}

/// A field that lost focus commits its composition, as native fields do.
pub fn processUnfocused(ui: *UI, id: Element.Id, buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: *State.TextInput, limits: Limits) !void {
    if (ui.composition_owner != id) return;
    var f = field(ui, id, buf, allocator, s, limits);
    try f.commitComposition();
    settle(ui, id, &f);
}

/// Clicking a composing field commits the composition, as native fields do.
pub fn commitOnPress(ui: *UI, id: Element.Id, f: *text_edit.Field) !void {
    if (!ui.input.mouseButton(.left).pressed or !ui.hovering(id)) return;
    try f.commitComposition();
}

pub const Layout = struct {
    ui: *UI,
    key: u64,
    size: f32,
    font: ?[]const u8,
    wrap_width: f32,
    features: [1]Feature = undefined,

    pub fn of(self: *Layout, value: []const u8, caret: u32) !*const TextLayout {
        return editLayout(self.ui, self.key, value, self.size, self.font, self.wrap_width, caretFeatures(value, caret, &self.features));
    }
};

/// Keys and text in order; text applies when it is typing or carries the field's session.
pub fn processEvents(frame: *Frame, id: Element.Id, f: *text_edit.Field, layout: *Layout, line_h: f32) !void {
    const ui = frame.ui();
    const session = ui.textSessionId(id);
    for (ui.input.events) |event| switch (event) {
        .text => |e| {
            if (!e.isTyping() and (session == null or e.session != session.?)) continue;
            try f.apply(e);
        },
        .key => |k| {
            if (k.action == .release) continue;
            const chord = input_types.clipboardModifierHeld(k.mods);
            if (chord and (k.key == .c or k.key == .x)) try copySelection(frame, f);
            if (text_edit.keyCommand(k, f.limits.multiline)) |command| {
                try f.run(command);
            } else if (f.limits.multiline) {
                try moveByLayout(ui, f, layout, k, line_h);
            }
        },
    };
}

fn copySelection(frame: *Frame, f: *const text_edit.Field) !void {
    if (f.composing()) return;
    const r = f.selection.range();
    if (r.start != r.end) try frame.writeClipboard(f.buf.items[r.start..r.end]);
}

fn moveByLayout(ui: *UI, f: *text_edit.Field, layout: *Layout, k: input_types.KeyEvent, line_h: f32) !void {
    switch (k.key) {
        .up, .down, .home, .end => {},
        else => return,
    }
    try f.commitComposition();
    const caret = f.selection.caret;
    const text_layout = try layout.of(f.buf.items, caret);
    const byte: u32 = switch (k.key) {
        .up, .down => blk: {
            const current = text_layout.pointForByte(caret);
            const offset = verticalOffset(k.key, line_h * ui.content_scale);
            break :blk text_layout.byteForPoint(.{ .x = current.x, .y = current.y + offset });
        },
        .home => lineBounds(text_layout, caret).start,
        else => lineBounds(text_layout, caret).end,
    };
    try f.run(.{ .move_to = .{ .byte = @min(byte, @as(u32, @intCast(f.buf.items.len))), .extend = k.mods.shift } });
}

pub fn processPaste(frame: *Frame, f: *text_edit.Field) !void {
    const paste_text = frame.pasteText() orelse return;
    const raw = try frame.arena().dupe(u8, paste_text);
    if (!std.unicode.utf8ValidateSlice(raw)) return;
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        // CRLF and CR become LF.
        if (raw[i] == '\r' and i + 1 < raw.len and raw[i + 1] == '\n') continue;
        raw[n] = if (raw[i] == '\r') '\n' else raw[i];
        n += 1;
    }
    if (n == 0) return;
    try f.run(.{ .insert = raw[0..n] });
}

/// What a field draws: its buffer with any composition in place.
pub const Display = struct {
    /// In the frame arena.
    text: []const u8,
    caret: u32,
    selection: TextRange,
    composition: ?TextRange,
};

pub fn display(frame: *Frame, f: *const text_edit.Field) !Display {
    const v = f.view();
    return .{ .text = try f.text(frame.arena()), .caret = v.caret, .selection = v.selection, .composition = v.composition };
}

/// A thin underline under the composition and a thick one under its active clause.
pub fn compositionUnderlines(frame: *Frame, d: Display) ![]const Decoration.Underline {
    const range = d.composition orelse return &.{};
    const ui = frame.ui();
    const segments = ui.composition.segments.items;
    const out = try frame.arena().alloc(Decoration.Underline, 1 + segments.len);
    out[0] = .{ .start = range.start, .end = range.end };
    var n: usize = 1;
    for (segments) |segment| {
        if (!segment.active) continue;
        out[n] = .{ .start = range.start + segment.start, .end = range.start + segment.end, .thick = true };
        n += 1;
    }
    return out[0..n];
}

/// `origin` is the text layout's top-left in the window, in logical pixels.
pub fn publishTextInput(frame: *Frame, id: Element.Id, d: Display, text_layout: *const TextLayout, origin: [2]f32, line_h: f32, limits: Limits) !void {
    const ui = frame.ui();
    const scale = ui.content_scale;
    const caret = text_layout.pointForByte(d.caret);
    var rects: []TextRect = &.{};
    if (d.composition) |range| {
        var spans: std.ArrayList(TextLayout.Rect) = .empty;
        try text_layout.selectionRects(frame.arena(), range.start, range.end, &spans);
        rects = try frame.arena().alloc(TextRect, spans.items.len);
        for (spans.items, rects) |sp, *r| r.* = .{
            .x = origin[0] + sp.x / scale,
            .y = origin[1] + sp.y / scale,
            .w = sp.w / scale,
            .h = line_h,
        };
    }
    ui.publishTextInput(id, .{
        .id = 0,
        .text = d.text,
        .selection = d.selection,
        .composition = d.composition,
        .composition_segments = if (d.composition != null) try frame.arena().dupe(input_types.CompositionSegment, ui.composition.segments.items) else &.{},
        .purpose = if (limits.multiline) .multiline else .text,
        .bytes_max = limits.bytes_max,
        .caret = .{ .x = origin[0] + caret.x / scale, .y = origin[1] + caret.y / scale, .w = 1, .h = line_h },
        .composition_rects = rects,
    });
}

pub fn byteToCharacter(bytes: []const u8, byte: u32) u32 {
    return Accessibility.byteToCharacter(bytes, byte);
}

fn characterToByte(bytes: []const u8, character: u32) u32 {
    return Accessibility.characterToByte(bytes, character);
}

pub fn validateByteLimit(bytes_max: u32) !void {
    if (bytes_max > text_bytes_max) return error.TextLimitTooLarge;
}

fn verticalOffset(key: input_types.Key, line_h: f32) f32 {
    return switch (key) {
        .up => -line_h * 0.5,
        else => line_h * 1.5,
    };
}

fn lineBounds(text_layout: *const TextLayout, byte: u32) struct { start: u32, end: u32 } {
    if (text_layout.lines.len == 0) return .{ .start = 0, .end = 0 };
    const line = text_layout.lines[text_layout.lineForByte(byte)];
    return .{ .start = line.byte_start, .end = line.byte_end };
}

pub fn processMouse(
    ui: *UI,
    id: Element.Id,
    buf: []const u8,
    s: *State.TextInput,
    text_layout: *const TextLayout,
    content_origin: [2]f32,
    scroll_offset: [2]f32,
    scale: f32,
) void {
    if (ui.input.mouseButton(.left).pressed and ui.hovering(id)) {
        const byte = byteAtMouse(ui, text_layout, content_origin, scroll_offset, scale, @intCast(buf.len));
        const double_click = if (s.last_click_ms) |last|
            ui.input.now_ms - last <= DOUBLE_CLICK_MS and s.last_click_byte == byte
        else
            false;

        if (double_click) {
            selectWordAtByte(buf, s, byte);
        } else {
            moveCursorToByte(buf, s, byte, ui.input.shift_held);
        }
        s.dragging = true;
        s.last_click_ms = ui.input.now_ms;
        s.last_click_byte = byte;
    }

    if (s.dragging and ui.input.mouseButton(.left).down) {
        const byte = byteAtMouse(ui, text_layout, content_origin, scroll_offset, scale, @intCast(buf.len));
        moveCursorToByte(buf, s, byte, true);
    }

    if (!ui.input.mouseButton(.left).down) s.dragging = false;
}

pub fn moveCursorToByte(buf: []const u8, s: *State.TextInput, byte: u32, extend: bool) void {
    const b = text_edit.floorGrapheme(buf, byte);
    s.selection.caret = b;
    if (!extend) s.selection.anchor = b;
}

pub fn selectWordAtByte(buf: []const u8, s: *State.TextInput, byte: u32) void {
    const word = text_edit.wordAt(buf, byte);
    s.selection = .{ .anchor = word.start, .caret = word.end };
}

fn byteAtMouse(
    ui: *UI,
    text_layout: *const TextLayout,
    content_origin: [2]f32,
    scroll_offset: [2]f32,
    scale: f32,
    len: u32,
) u32 {
    const x = @as(f32, @floatCast(ui.input.mouse_pos[0])) - content_origin[0] + scroll_offset[0];
    const y = @as(f32, @floatCast(ui.input.mouse_pos[1])) - content_origin[1] + scroll_offset[1];
    return @min(text_layout.byteForPoint(.{ .x = x * scale, .y = y * scale }), len);
}

test "text byte limit accepts one MiB and rejects one byte more" {
    try validateByteLimit(text_bytes_max);
    try std.testing.expectError(
        error.TextLimitTooLarge,
        validateByteLimit(text_bytes_max + 1),
    );
}

test "selection deletion remains available above a smaller caller limit" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "abcde");
    var composition: text_edit.Composition = .{};
    var selection: text_edit.Selection = .{ .anchor = 3, .caret = 5 };
    var f: text_edit.Field = .{
        .buf = &buf,
        .allocator = std.testing.allocator,
        .selection = &selection,
        .composition = &composition,
        .composition_allocator = std.testing.allocator,
        .owns_composition = false,
        .limits = .{ .multiline = false, .bytes_max = 3 },
    };
    try f.run(.delete_selection);
    try std.testing.expectEqualStrings("abc", buf.items);
    try std.testing.expectEqual(text_edit.Selection.at(3), selection);
}

test "caret features cover the operator run around the caret" {
    var storage: [1]Feature = undefined;
    const features = caretFeatures("a != b", 3, &storage);
    try std.testing.expectEqual(@as(u32, 2), features[0].start);
    try std.testing.expectEqual(@as(u32, 4), features[0].end);
}

test "selection maps bytes to characters" {
    const value = "a\u{1F44D}\u{1F3FD}e\u{0301}";
    try std.testing.expectEqual(@as(u32, 1), byteToCharacter(value, 1));
    try std.testing.expectEqual(@as(u32, 2), byteToCharacter(value, 9));
}
