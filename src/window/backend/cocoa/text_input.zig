//! NSTextInputClient for KnotsView. AppKit's UTF-16 offsets become bytes here.
const std = @import("std");
const objc = @import("objc");
const input_types = @import("input");
const window = @import("window");
const ak = @import("appkit.zig");

const c = ak.c;
const Window = window.Window;
const State = window.TextInputState;
const TextRange = input_types.TextRange;
const Segment = input_types.CompositionSegment;

const not_found: c_ulong = std.math.maxInt(c_long);
const NSUnderlineStyleThick: c_long = 0x02;

pub const text_input_methods = .{
    .{ "insertText:replacementRange:", insertText },
    .{ "doCommandBySelector:", doCommandBySelector },
    .{ "setMarkedText:selectedRange:replacementRange:", setMarkedText },
    .{ "unmarkText", unmarkText },
    .{ "hasMarkedText", hasMarkedText },
    .{ "markedRange", markedRange },
    .{ "selectedRange", selectedRange },
    .{ "validAttributesForMarkedText", validAttributes },
    .{ "attributedSubstringForProposedRange:actualRange:", attributedSubstring },
    .{ "characterIndexForPoint:", characterIndexForPoint },
    .{ "firstRectForCharacterRange:actualRange:", firstRectForCharacterRange },
};

/// Without the protocol, `-[NSView inputContext]` is nil and no input method runs.
pub fn adoptProtocol(cls: objc.Class) bool {
    const protocol = c.objc_getProtocol("NSTextInputClient") orelse return false;
    const added = c.class_addProtocol(cls.value, protocol);
    return switch (c.BOOL) {
        bool => added,
        i8 => added != 0,
        else => @compileError("unexpected BOOL type"),
    };
}

fn session(self: c.id) ?*Window {
    const owner = ak.unwrapOwner(self) orelse return null;
    return if (owner.text_input.active) owner else null;
}

fn plainString(string_id: c.id) objc.Object {
    const obj = objc.Object.fromId(string_id);
    const is_attr = obj.msgSend(bool, "isKindOfClass:", .{objc.getClass("NSAttributedString").?});
    return if (is_attr) obj.msgSend(objc.Object, "string", .{}) else obj;
}

fn utf8(ns_str: objc.Object) []const u8 {
    const ptr: ?[*:0]const u8 = ns_str.msgSend(?[*:0]const u8, "UTF8String", .{});
    return std.mem.sliceTo(ptr orelse return "", 0);
}

/// `not_found` means the composition, else the selection.
fn byteRange(state: *const State, r: ak.NSRange) TextRange {
    if (r.location == not_found) return state.target();
    const start: u32 = @intCast(@min(r.location, std.math.maxInt(u32)));
    const end: u32 = @intCast(@min(r.location +| r.length, std.math.maxInt(u32)));
    return State.byteRange(state.text.items, .{ .start = start, .end = end });
}

/// `not_found` leaves the range to the field.
fn editRange(state: *const State, r: ak.NSRange) ?TextRange {
    if (r.location == not_found) return null;
    return byteRange(state, r);
}

fn nsRange(text: []const u8, r: TextRange) ak.NSRange {
    const u = State.utf16Range(text, r);
    return .{ .location = u.start, .length = u.len() };
}

fn insertText(self: c.id, _: c.SEL, string_id: c.id, replacement: ak.NSRange) callconv(.c) void {
    const text = utf8(plainString(string_id));
    const owner = session(self) orelse {
        if (ak.unwrapOwner(self)) |o| ak.pushUtf8Chars(o, text, false);
        return;
    };
    owner.pushTextEdit(.{
        .session = owner.text_input.id,
        .replace = editRange(&owner.text_input, replacement),
        .text = text,
    });
}

/// Keys already reached the UI as key events; editing commands need nothing more.
fn doCommandBySelector(_: c.id, _: c.SEL, _: c.SEL) callconv(.c) void {}

fn setMarkedText(self: c.id, _: c.SEL, string_id: c.id, selected: ak.NSRange, replacement: ak.NSRange) callconv(.c) void {
    const owner = session(self) orelse return;
    const plain = plainString(string_id);
    const text = utf8(plain);

    var segments_buf: [32]Segment = undefined;
    const segments = clauseSegments(objc.Object.fromId(string_id), text, &segments_buf);

    const caret_start: u32 = @intCast(@min(selected.location, std.math.maxInt(u32)));
    const caret_end: u32 = @intCast(@min(selected.location +| selected.length, std.math.maxInt(u32)));
    owner.pushTextEdit(.{
        .session = owner.text_input.id,
        .replace = editRange(&owner.text_input, replacement),
        .text = text,
        .compose = .{
            .caret = State.byteRange(text, .{ .start = caret_start, .end = caret_end }),
            .segments = segments,
        },
    });
}

/// Clauses the input method marked with underlines; the thick one is being converted.
fn clauseSegments(string: objc.Object, text: []const u8, out: []Segment) []const Segment {
    const is_attr = string.msgSend(bool, "isKindOfClass:", .{objc.getClass("NSAttributedString").?});
    if (!is_attr) return &.{};
    const units = string.msgSend(c_ulong, "length", .{});
    const key = ak.nsstring("NSUnderline");
    var n: usize = 0;
    var index: c_ulong = 0;
    while (index < units and n < out.len) {
        var effective: ak.NSRange = .{ .location = 0, .length = 0 };
        const value = string.msgSend(objc.Object, "attribute:atIndex:effectiveRange:", .{ key, index, &effective });
        if (effective.length == 0) break;
        if (value.value != null) {
            const style = value.msgSend(c_long, "integerValue", .{});
            const r = State.byteRange(text, .{
                .start = @intCast(effective.location),
                .end = @intCast(effective.location + effective.length),
            });
            if (r.start < r.end) {
                out[n] = .{ .start = r.start, .end = r.end, .active = (style & NSUnderlineStyleThick) != 0 };
                n += 1;
            }
        }
        index = effective.location + effective.length;
    }
    return out[0..n];
}

fn unmarkText(self: c.id, _: c.SEL) callconv(.c) void {
    const owner = session(self) orelse return;
    const composition = owner.text_input.composition orelse return;
    const text = owner.text_input.text.items[composition.start..composition.end];
    owner.pushTextEdit(.{ .session = owner.text_input.id, .replace = composition, .text = text });
}

fn hasMarkedText(self: c.id, _: c.SEL) callconv(.c) c.BOOL {
    const owner = session(self) orelse return ak.boolParam(false);
    return ak.boolParam(owner.text_input.composition != null);
}

fn markedRange(self: c.id, _: c.SEL) callconv(.c) ak.NSRange {
    const owner = session(self) orelse return .{ .location = not_found, .length = 0 };
    const composition = owner.text_input.composition orelse return .{ .location = not_found, .length = 0 };
    return nsRange(owner.text_input.text.items, composition);
}

fn selectedRange(self: c.id, _: c.SEL) callconv(.c) ak.NSRange {
    const owner = session(self) orelse return .{ .location = not_found, .length = 0 };
    return nsRange(owner.text_input.text.items, owner.text_input.selection);
}

fn validAttributes(_: c.id, _: c.SEL) callconv(.c) c.id {
    const NSArray = objc.getClass("NSArray").?;
    const underline = ak.nsstring("NSUnderline");
    const clause = ak.nsstring("NSMarkedClauseSegment");
    return NSArray.msgSend(objc.Object, "arrayWithObjects:count:", .{ &[_]c.id{ underline.value, clause.value }, @as(c_ulong, 2) }).value;
}

fn attributedSubstring(self: c.id, _: c.SEL, proposed: ak.NSRange, actual: ?*ak.NSRange) callconv(.c) c.id {
    const owner = session(self) orelse return null;
    const text = owner.text_input.text.items;
    const r = byteRange(&owner.text_input, proposed);
    if (actual) |a| a.* = nsRange(text, r);
    const NSAttributedString = objc.getClass("NSAttributedString").?;
    const string = NSAttributedString.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithString:", .{ak.nsstring(text[r.start..r.end])});
    return string.msgSend(objc.Object, "autorelease", .{}).value;
}

fn characterIndexForPoint(_: c.id, _: c.SEL, _: ak.NSPoint) callconv(.c) c_ulong {
    return not_found;
}

/// For the candidate window: the composition line, else the caret.
fn firstRectForCharacterRange(self: c.id, _: c.SEL, range: ak.NSRange, actual: ?*ak.NSRange) callconv(.c) ak.NSRect {
    const zero: ak.NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    const owner = session(self) orelse return zero;
    const r = byteRange(&owner.text_input, range);
    if (actual) |a| a.* = nsRange(owner.text_input.text.items, r);
    const rect = owner.text_input.rectFor(r.start);

    const view = objc.Object.fromId(self);
    const in_view: ak.NSRect = .{ .origin = .{ .x = rect.x, .y = rect.y }, .size = .{ .width = rect.w, .height = rect.h } };
    const in_window = view.msgSend(ak.NSRect, "convertRect:toView:", .{ in_view, @as(c.id, null) });
    const ns_window = view.msgSend(objc.Object, "window", .{});
    if (ns_window.value == null) return zero;
    return ns_window.msgSend(ak.NSRect, "convertRectToScreen:", .{in_window});
}

pub fn update(view: objc.Object, owner: *Window, change: State.Change) void {
    const context = view.msgSend(objc.Object, "inputContext", .{});
    if (context.value == null) return;
    if (change.started or change.ended or change.composition_dropped) {
        context.msgSend(void, "discardMarkedText", .{});
    }
    if (owner.text_input.composition != null) context.msgSend(void, "invalidateCharacterCoordinates", .{});
}
