const objc = @import("objc");

pub const c = objc.c;

pub const IVAR_OWNER: [:0]const u8 = "knots_owner";

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };
pub const NSRange = extern struct { location: c_ulong, length: c_ulong };

pub const NSWindowStyleMaskBorderless: c_ulong = 0;
pub const NSWindowStyleMaskTitled: c_ulong = 1 << 0;
pub const NSWindowStyleMaskClosable: c_ulong = 1 << 1;
pub const NSWindowStyleMaskMiniaturizable: c_ulong = 1 << 2;
pub const NSWindowStyleMaskResizable: c_ulong = 1 << 3;
pub const NSWindowStyleMaskFullScreen: c_ulong = 1 << 14;

pub const NSNormalWindowLevel: c_long = 0;
pub const NSMainMenuWindowLevel: c_long = 24;

pub const NSBackingStoreBuffered: c_ulong = 2;
pub const NSApplicationActivationPolicyRegular: c_long = 0;
pub const NSEventMaskAny: c_ulong = @import("std").math.maxInt(c_ulong);
pub const NSEventTypeApplicationDefined: c_ulong = 15;

pub const NSEventModifierFlagShift: c_ulong = 1 << 17;
pub const NSEventModifierFlagControl: c_ulong = 1 << 18;
pub const NSEventModifierFlagOption: c_ulong = 1 << 19;
pub const NSEventModifierFlagCommand: c_ulong = 1 << 20;

pub const NSDragOperationCopy: c_ulong = 1;
pub const NSUTF8StringEncoding: c_ulong = 4;

pub extern const NSDefaultRunLoopMode: c.id;
pub extern const NSEventTrackingRunLoopMode: c.id;
pub extern const NSPasteboardTypeFileURL: c.id;
pub extern const NSPasteboardTypeString: c.id;

pub fn boolParam(b: bool) c.BOOL {
    return switch (c.BOOL) {
        bool => b,
        i8 => @intFromBool(b),
        else => @compileError("unexpected BOOL type"),
    };
}

pub fn sharedApp() objc.Object {
    const NSApplication = objc.getClass("NSApplication").?;
    return NSApplication.msgSend(objc.Object, "sharedApplication", .{});
}

pub fn defaultRunLoopMode() objc.Object {
    return .{ .value = NSDefaultRunLoopMode };
}

pub fn eventTrackingRunLoopMode() objc.Object {
    return .{ .value = NSEventTrackingRunLoopMode };
}

pub fn nsstring(s: []const u8) objc.Object {
    var buf: [512]u8 = undefined;
    const len = @min(s.len, buf.len - 1);
    @memcpy(buf[0..len], s[0..len]);
    buf[len] = 0;
    const NSString = objc.getClass("NSString").?;
    return NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*:0]const u8, @ptrCast(&buf))});
}

pub fn wrapPointer(ptr: anytype) objc.Object {
    const NSValue = objc.getClass("NSValue").?;
    return NSValue.msgSend(objc.Object, "valueWithPointer:", .{@as(*const anyopaque, @ptrCast(ptr))});
}

const std = @import("std");
const Window = @import("window").Window;

pub fn unwrapOwner(self_id: c.id) ?*Window {
    const obj = objc.Object.fromId(self_id);
    const value = obj.getInstanceVariable(IVAR_OWNER);
    if (value.value == null) return null;
    const ptr = value.msgSend(?*anyopaque, "pointerValue", .{}) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

pub fn pushUtf8Chars(owner: *Window, slice: []const u8, comptime filter_function_keys: bool) void {
    var i: usize = 0;
    while (i < slice.len) {
        const len = std.unicode.utf8ByteSequenceLength(slice[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > slice.len) break;
        const cp = std.unicode.utf8Decode(slice[i..][0..len]) catch {
            i += len;
            continue;
        };
        i += len;
        if (cp < 0x20 or cp == 0x7F) continue;

        // 0xF700-0xF8FF is the NSFunctionKey range AppKit emits for arrow keys, F-keys, etc, those must stay out of the chars channel.
        if (filter_function_keys and cp >= 0xF700 and cp <= 0xF8FF) continue;
        owner.pushChar(cp);
    }
}
