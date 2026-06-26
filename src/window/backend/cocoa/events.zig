const objc = @import("objc");
const window = @import("window");
const ak = @import("appkit.zig");
const keymap = @import("keymap.zig");

const c = ak.c;
const Window = @import("window").Window;

pub const view_misc_methods = .{
    .{ "acceptsFirstResponder", acceptsFirstResponder },
    .{ "isFlipped", isFlipped },
};

pub const mouse_methods = .{
    .{ "mouseDown:", mouseLeftDown },
    .{ "mouseUp:", mouseLeftUp },
    .{ "mouseMoved:", mouseMoved },
    .{ "mouseDragged:", mouseDragged },
    .{ "rightMouseDown:", mouseRightDown },
    .{ "rightMouseUp:", mouseRightUp },
    .{ "rightMouseDragged:", rightMouseDragged },
    .{ "otherMouseDown:", otherMouseDown },
    .{ "otherMouseUp:", otherMouseUp },
    .{ "otherMouseDragged:", otherMouseDragged },
    .{ "scrollWheel:", scrollWheel },
};

pub const keyboard_methods = .{
    .{ "keyDown:", keyDown },
    .{ "keyUp:", keyUp },
    .{ "flagsChanged:", flagsChanged },
};

pub const drag_methods = .{
    .{ "draggingEntered:", draggingEntered },
    .{ "performDragOperation:", performDragOperation },
};

pub const delegate_methods = .{
    .{ "windowShouldClose:", windowShouldClose },
    .{ "windowDidBecomeKey:", windowDidBecomeKey },
    .{ "windowDidResignKey:", windowDidResignKey },
    .{ "windowDidEnterFullScreen:", windowDidEnterFullScreen },
    .{ "windowDidExitFullScreen:", windowDidExitFullScreen },
    .{ "windowDidResize:", windowDidResize },
    .{ "windowDidEndLiveResize:", windowDidEndLiveResize },
};

fn acceptsFirstResponder(_: c.id, _: c.SEL) callconv(.c) c.BOOL {
    return ak.boolParam(true);
}

fn isFlipped(_: c.id, _: c.SEL) callconv(.c) c.BOOL {
    return ak.boolParam(true);
}

fn eventPos(self: c.id, event_id: c.id) [2]f64 {
    const view = objc.Object.fromId(self);
    const event = objc.Object.fromId(event_id);
    const point_in_window = event.msgSend(ak.NSPoint, "locationInWindow", .{});
    const point = view.msgSend(ak.NSPoint, "convertPoint:fromView:", .{ point_in_window, @as(c.id, null) });
    return .{ point.x, point.y };
}

fn mouseLeftDown(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setMouseButton(.left, true, eventPos(self, event_id));
}

fn mouseLeftUp(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setMouseButton(.left, false, eventPos(self, event_id));
}

fn mouseMoved(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setCursorPos(eventPos(self, event_id));
}

fn mouseDragged(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setCursorPos(eventPos(self, event_id));
}

fn mouseRightDown(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setMouseButton(.right, true, eventPos(self, event_id));
}

fn mouseRightUp(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setMouseButton(.right, false, eventPos(self, event_id));
}

fn rightMouseDragged(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setCursorPos(eventPos(self, event_id));
}

fn otherMouseDown(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    const event = objc.Object.fromId(event_id);
    const number = event.msgSend(c_long, "buttonNumber", .{});
    const button: window.MouseButton = switch (number) {
        2 => .middle,
        3 => .back,
        4 => .forward,
        else => return,
    };
    owner.setMouseButton(button, true, eventPos(self, event_id));
}

fn otherMouseUp(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    const event = objc.Object.fromId(event_id);
    const number = event.msgSend(c_long, "buttonNumber", .{});
    const button: window.MouseButton = switch (number) {
        2 => .middle,
        3 => .back,
        4 => .forward,
        else => return,
    };
    owner.setMouseButton(button, false, eventPos(self, event_id));
}

fn otherMouseDragged(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setCursorPos(eventPos(self, event_id));
}

fn scrollWheel(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setCursorPos(eventPos(self, event_id));
    const event = objc.Object.fromId(event_id);
    const dx = event.msgSend(f64, "scrollingDeltaX", .{});
    const dy = event.msgSend(f64, "scrollingDeltaY", .{});
    const precise = event.msgSend(bool, "hasPreciseScrollingDeltas", .{});
    if (precise)
        owner.addScrollPixels(dx, -dy)
    else
        owner.addScrollLines(dx, -dy);
}

fn keyDown(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    const event = objc.Object.fromId(event_id);
    const kc = event.msgSend(u16, "keyCode", .{});
    const flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const key = keymap.translateKeyCode(kc);
    const mods = modsFromFlags(flags);
    owner.pushKey(@intFromEnum(key), .press, mods);

    const skip_chars = (flags & ak.NSEventModifierFlagCommand) != 0 or
        (flags & ak.NSEventModifierFlagControl) != 0;
    if (skip_chars) return;

    const view = objc.Object.fromId(self);
    const input_context = view.msgSend(objc.Object, "inputContext", .{});
    if (input_context.value != null and input_context.msgSend(bool, "handleEvent:", .{event})) return;

    const characters = event.msgSend(objc.Object, "characters", .{});
    if (characters.value == null) return;
    const utf8: [*:0]const u8 = characters.msgSend([*:0]const u8, "UTF8String", .{});
    const slice = @import("std").mem.sliceTo(utf8, 0);
    ak.pushUtf8Chars(owner, slice, true);
}

fn keyUp(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    const event = objc.Object.fromId(event_id);
    const kc = event.msgSend(u16, "keyCode", .{});
    const flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const key = keymap.translateKeyCode(kc);
    owner.pushKey(@intFromEnum(key), .release, modsFromFlags(flags));
}

fn flagsChanged(self: c.id, _: c.SEL, event_id: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    const event = objc.Object.fromId(event_id);
    const kc = event.msgSend(u16, "keyCode", .{});
    const flags = event.msgSend(c_ulong, "modifierFlags", .{});
    const key = keymap.translateKeyCode(kc);
    // Derive press vs release: check whether the modifier bit corresponding
    // to the changed key is currently set in modifierFlags.
    const key_bit: c_ulong = switch (kc) {
        0x37, 0x36 => ak.NSEventModifierFlagCommand,
        0x38, 0x3C => ak.NSEventModifierFlagShift,
        0x3A, 0x3D => ak.NSEventModifierFlagOption,
        0x3B, 0x3E => ak.NSEventModifierFlagControl,
        else => 0,
    };
    const action: window.KeyAction = if (key_bit != 0 and (flags & key_bit) != 0) .press else .release;
    owner.pushKey(@intFromEnum(key), action, modsFromFlags(flags));
}

fn draggingEntered(_: c.id, _: c.SEL, _: c.id) callconv(.c) c_ulong {
    return ak.NSDragOperationCopy;
}

fn performDragOperation(self: c.id, _: c.SEL, sender_id: c.id) callconv(.c) c.BOOL {
    const owner = ak.unwrapOwner(self) orelse return ak.boolParam(false);
    const sender = objc.Object.fromId(sender_id);
    const pasteboard = sender.msgSend(objc.Object, "draggingPasteboard", .{});
    if (pasteboard.value == null) return ak.boolParam(false);

    const NSURL = objc.getClass("NSURL").?;
    const NSArray = objc.getClass("NSArray").?;
    const classes_array = NSArray.msgSend(objc.Object, "arrayWithObject:", .{objc.Object{ .value = @ptrCast(@alignCast(NSURL.value)) }});
    const urls = pasteboard.msgSend(objc.Object, "readObjectsForClasses:options:", .{ classes_array, @as(c.id, null) });
    if (urls.value == null) return ak.boolParam(false);

    const be = &owner.backend;
    const count = urls.msgSend(c_ulong, "count", .{});
    const n: usize = @min(@as(usize, count), be.drop_paths_buf.len);
    for (0..n) |i| {
        const url = urls.msgSend(objc.Object, "objectAtIndex:", .{@as(c_ulong, i)});
        const c_path = url.msgSend([*:0]const u8, "fileSystemRepresentation", .{});
        const slice = @import("std").mem.sliceTo(c_path, 0);
        const len = @min(slice.len, be.drop_paths_buf[i].len);
        @memcpy(be.drop_paths_buf[i][0..len], slice[0..len]);
        be.drop_slices[i] = be.drop_paths_buf[i][0..len];
    }
    owner.markDropped(n);
    return ak.boolParam(true);
}

fn windowShouldClose(self: c.id, _: c.SEL, _: c.id) callconv(.c) c.BOOL {
    const owner = ak.unwrapOwner(self) orelse return ak.boolParam(true);
    owner.markClosed();
    return ak.boolParam(false);
}

fn windowDidBecomeKey(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setFocused(true);
    const NSEvent = objc.getClass("NSEvent").?;
    owner.setMods(modsFromFlags(NSEvent.msgSend(c_ulong, "modifierFlags", .{})));
}

fn windowDidResignKey(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.setFocused(false);
}

fn windowDidEnterFullScreen(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.backend.display_mode = .fullscreen;
    if (!owner.backend.display_mode_transition) owner.backend.desired_display_mode = .fullscreen;
    owner.backend.display_mode_transition = false;
    owner.requestFrame();
    owner.backend.reconcileDisplayMode();
}

fn windowDidExitFullScreen(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.backend.display_mode = .windowed;
    if (!owner.backend.display_mode_transition) owner.backend.desired_display_mode = .windowed;
    owner.backend.display_mode_transition = false;
    owner.requestFrame();
    owner.backend.reconcileDisplayMode();
}

fn windowDidResize(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.markResized();
    owner.requestFrame();
}

fn windowDidEndLiveResize(self: c.id, _: c.SEL, _: c.id) callconv(.c) void {
    const owner = ak.unwrapOwner(self) orelse return;
    owner.markResized();
    owner.requestFrame();
}

fn modsFromFlags(flags: c_ulong) window.Mods {
    return .{
        .shift = (flags & ak.NSEventModifierFlagShift) != 0,
        .ctrl = (flags & ak.NSEventModifierFlagControl) != 0,
        .alt = (flags & ak.NSEventModifierFlagOption) != 0,
        .super = (flags & ak.NSEventModifierFlagCommand) != 0,
    };
}
